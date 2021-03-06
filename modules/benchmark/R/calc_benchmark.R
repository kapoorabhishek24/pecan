##-------------------------------------------------------------------------------------------------#
##' For each benchmark id, calculate metrics and update benchmarks_ensemble_scores
##'  
##' @name calc_benchmark 
##' @title Calculate benchmarking statistics
##' @param bm.ensemble object, either from create_BRR or start.bm.ensemle
##' @param bety database connection
##' @export 
##' 
##' @author Betsy Cowdery 
##' @importFrom dplyr tbl filter rename collect select
calc_benchmark <- function(settings, bety) {
  
  # Update benchmarks_ensembles and benchmarks_ensembles_scores tables
  
  ensemble <- tbl(bety,'ensembles') %>% filter(workflow_id == settings$workflow$id) %>% collect()
  
  # Retrieve/create benchmark ensemble database record
  bm.ensemble <- tbl(bety,'benchmarks_ensembles') %>% 
    filter(reference_run_id == settings$benchmarking$reference_run_id,
           ensemble_id == ensemble$id,
           model_id == settings$model$id) %>%
    collect()
  
  if(dim(bm.ensemble)[1] == 0){
    bm.ensemble <- db.query(paste0("INSERT INTO benchmarks_ensembles",
                                   "(reference_run_id, ensemble_id, model_id, ",
                                   "user_id, citation_id)",
                                   "VALUES(",settings$benchmarking$reference_run_id,
                                   ", ",ensemble$id,
                                   ", ",settings$model$id,", ",settings$info$userid,
                                   ", 1000000001 ) RETURNING *;"), bety$con)
  }else if(dim(bm.ensemble)[1] >1){
    PEcAn.utils::logger.error("Duplicate record entries in benchmarks_ensembles")
  }
  
  # --------------------------------------------------------------------------------------------- #
  # Setup
  
  site <- PEcAn.DB::query.site(settings$run$site$id, bety$con)
  start_year <- lubridate::year(settings$run$start.date)
  end_year <- lubridate::year(settings$run$end.date)
  model_run <- dir(settings$modeloutdir, full.names = TRUE, include.dirs = TRUE)[1]
  # How are we dealing with ensemble runs? Right now I've hardcoded to select the first run.
  
  # All benchmarking records for the given benchmarking ensemble id
  bms <- tbl(bety,'benchmarks') %>% rename(benchmark_id = id) %>%  
    left_join(tbl(bety, "benchmarks_benchmarks_reference_runs"), by="benchmark_id") %>% 
    filter(reference_run_id == settings$benchmarking$reference_run_id) %>% 
    select(one_of("benchmark_id", "input_id", "site_id", "variable_id", "reference_run_id")) %>%
    collect() %>%
    filter(benchmark_id %in% unlist(settings$benchmarking[which(names(settings$benchmarking) == "benchmark_id")]))
  
  var.ids <- bms$variable_id
  
  # --------------------------------------------------------------------------------------------- #
  # Determine how many data sets inputs are associated with the benchmark id's
  # bm.ids are split up in to groups according to their input data. 
  # So that the input data is only loaded once. 
  
  results <- list()
  
  for (input.id in unique(bms$input_id)) {
    
    bm.ids <- bms$benchmark_id[which(bms$input_id == input.id)]
    data.path <- PEcAn.DB::query.file.path(input.id, settings$host$name, bety$con)
    format_full <- format <- PEcAn.DB::query.format.vars(input.id = input.id, bety, format.id = NA, var.ids=var.ids)
    
    # ---- LOAD INPUT DATA ---- #
    
    time.row <- format$time.row
    vars.used.index <- setdiff(seq_along(format$vars$variable_id), format$time.row)
    
    obvs <- load_data(data.path, format, start_year, end_year, site, vars.used.index, time.row)
    dat_vars <- format$vars$pecan_name  # IF : is this line redundant?
    obvs_full <- obvs
    
    # ---- LOAD MODEL DATA ---- #
    
    model_vars <- format$vars$pecan_name[-time.row]  # IF : what will happen when time.row is NULL? 
    # For example 'AmeriFlux.level2.h.nc' format (38) has time vars year-day-hour listed, 
    # but storage type column is empty and it should be because in load_netcdf we extract
    # the time from netcdf files using the time dimension we can remove time variables from
    # this format's related variables list or can hardcode 'time.row=NULL' in load_x_netcdf function
    model <- as.data.frame(read.output(runid = basename(model_run), 
                                       outdir = model_run, 
                                       start.year = start_year, 
                                       end.year = end_year,
                                       c("time", model_vars)))
    vars.used.index <- which(format$vars$pecan_name %in% names(model)[!names(model) == "time"])
    
    # We know that the model output time is days since the beginning of the year.
    # Make a column of years to supplement the column of days of the year.
    years <- start_year:end_year
    Diff <- diff(model$time)
    time_breaks = which(Diff < 0)
    if(length(time_breaks) == 0 & length(years)>1){
      ## continuous time
      model$year <- rep(years,each=round(365/median(Diff)))
      model$posix <- as.POSIXct(model$time*86400,origin=settings$run$start.date,tz="UTC")
    } else {
      n <- model$time[c(time_breaks, length(model$time))]
      y <- c()
      for (i in seq_along(n)) {
        y <- c(y, rep(years[i], n[i]))
      }
      model$year <- y
    } 
    model_full <- model
    
    # ---- CALCULATE BENCHMARK SCORES ---- #
    
    results.list <- list()
    dat.list <- list()
    var.list <- c()
    
    # Loop over benchmark ids
    for (i in seq_along(bm.ids)) {
      bm <- db.query(paste("SELECT * from benchmarks where id =", bm.ids[i]), bety$con)
      metrics <- db.query(paste("SELECT m.name, m.id from metrics as m", 
                                "JOIN benchmarks_metrics as b ON m.id = b.metric_id", 
                                "WHERE b.benchmark_id = ", bm.ids[i]), bety$con) # %>% filter(id %in% metric.ids)
      var <- filter(format$vars, variable_id == bm$variable_id)[, "pecan_name"]
      var.list <- c(var.list, var)
      
      obvs.calc <- obvs_full %>% select(., one_of(c("posix", var)))
      obvs.calc[,var] <- as.numeric(obvs.calc[,var])
      model.calc <- model_full %>% select(., one_of(c("posix", var)))
      
      # TODO: If the scores have already been calculated, don't redo
      
      out.calc_metrics <- calc_metrics(model.calc, 
                                       obvs.calc, 
                                       var, 
                                       metrics,
                                       start_year, end_year, 
                                       bm,
                                       ensemble.id = bm.ensemble$ensemble_id,
                                       model_run)
      
      for(metric.id in metrics$id){
        metric.name <- filter(metrics,id == metric.id)[["name"]]
        score <- out.calc_metrics[["benchmarks"]] %>% filter(metric == metric.name) %>% select(score)
        
        # Update scores in the database
        
        score.entry <- tbl(bety, "benchmarks_ensembles_scores") %>%
          filter(benchmark_id == bm.ids[i]) %>%
          filter(benchmarks_ensemble_id == bm.ensemble$id) %>%
          filter(metric_id == metric.id) %>% 
          collect()
        
        # If the score is already in the database, should check if it is the same as the calculated 
        # score. But this requires a well written regular expression since it can be matching text. 
        
        if(dim(score.entry)[1] == 0){
          db.query(paste0(
            "INSERT INTO benchmarks_ensembles_scores",
            "(score, benchmarks_ensemble_id, benchmark_id, metric_id) VALUES ",
            "('",score,"',",bm.ensemble$id,", ",bm$id,",",metric.id,")"),bety$con)
        }else if(dim(score.entry)[1] >1){
          PEcAn.utils::logger.error("Duplicate record entries in scores")
        }
      }
      results.list <- append(results.list, list(out.calc_metrics[["benchmarks"]]))
      dat.list <- append(dat.list, list(out.calc_metrics[["dat"]]))
    }  #end loop over benchmark ids
    
    table.filename <- file.path(dirname(dirname(model_run)), 
                                paste("benchmark.scores", var, bm.ensemble$ensemble_id, "pdf", sep = "."))
    pdf(file = table.filename)
    gridExtra::grid.table(do.call(rbind, results.list))
    dev.off()
    
    names(dat.list) <- var.list
    results <- append(results, 
                      list(list(bench.results = do.call(rbind, results.list),
                                data.path = data.path, 
                                format = format_full$vars, 
                                model = model_full, 
                                obvs = obvs_full, 
                                aligned.dat = dat.list)))
  }
  
  names(results) <- sprintf("input.%0.f", unique(bms$input_id))
  save(results, file = file.path(settings$outdir,"benchmarking.output.Rdata"))
  
  return(invisible(results))
} # calc_benchmark
