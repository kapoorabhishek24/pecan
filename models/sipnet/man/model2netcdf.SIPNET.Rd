\name{model2netcdf.SIPNET}
\alias{model2netcdf.SIPNET}
\title{Function to convert SIPNET model output to standard netCDF format}
\usage{
  model2netcdf.SIPNET(outdir, sitelat, sitelon, start_date,
    end_date)
}
\arguments{
  \item{outdir}{Location of SIPNET model output}

  \item{sitelat}{Latitude of the site}

  \item{sitelon}{Longitude of the site}

  \item{start_date}{Start time of the simulation}

  \item{end_date}{End time of the simulation}
}
\description{
  Convert SIPNET output to netCDF
}
\details{
  Converts all output contained in a folder to netCDF.
}
\author{
  Shawn Serbin, Michael Dietze
}
