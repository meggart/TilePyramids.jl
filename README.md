# TilePyramids

[![Build Status](https://github.com/meggart/TilePyramids.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/meggart/TilePyramids.jl/actions/workflows/CI.yml?query=branch%3Amain)

## Expose Pyramids as MapTiles

Example:

````julia
import PyramidScheme as PS
using Tyler: Map, wgs84
using Extents: Extent
import GLMakie
using TilePyramids

p2020 = PS.Pyramid("https://s3.bgc-jena.mpg.de:9000/pyramids/ESACCI-BIOMASS-L4-AGB-MERGED-100m-2020-fv4.0.zarr")

datarange = (0.0,400.0)

pv = PyramidProvider(p2020,datarange...,colorscheme=:speed)

ext = Extent(X=(-180.0,180.0),Y=(-60.0,80.0))

Map(ext,wgs84,provider=pv,crs=wgs84)
````

