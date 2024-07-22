# TilePyramids

[![Build Status](https://github.com/meggart/TilePyramids.jl/actions/workflows/CI.yml/badge.svg?branch=main)](https://github.com/meggart/TilePyramids.jl/actions/workflows/CI.yml?query=branch%3Amain)

## Exposing Pyramids as MapTiles

### Create a Tyler Map directly from a Pyramid

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

### Create a custom HTTP tile server from a Pyramid

````julia
import PyramidScheme as PS
using TilePyramids
import HTTP
p2020 = PS.Pyramid("https://s3.bgc-jena.mpg.de:9000/pyramids/ESACCI-BIOMASS-L4-AGB-MERGED-100m-2020-fv4.0.zarr")
datarange = (0.0,400.0)

pv = PyramidProvider(p2020,datarange...,colorscheme=:speed)
s = HTTP.serve!(pv,"127.0.0.1",8765)
````

Now we can either download a tile:

````julia
import Downloads, FileIO
f = Downloads.download("http://127.0.0.1:8765/1/1/0.png")
FileIO.load(f)
````

or we create a custom TileProvider and use Tyler to access an area:

````julia
import TileProviders, Tyler, Extents
prov = TileProviders.Provider("http://127.0.0.1:8765/{z}/{x}/{y}.png")
Tyler.Map(Extents.Extent(X=(30.0,30.5),Y=(50.0,50.5)),provider=prov)
````


