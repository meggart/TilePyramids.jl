module TilePyramids

using PyramidScheme: Pyramid, nlevels, levels
import TileProviders
using ColorSchemes: colorschemes
using Colors: @colorant_str, RGB
using Extents: Extent, bounds
using MapTiles: Tile, extent, wgs84
import Tyler
using DimensionalData: Near, DimArray
using FileIO: Stream, @format_str, save
import ImageMagick
import HTTP
export PyramidProvider

struct PyramidProvider{P<:Pyramid} <: TileProviders.AbstractProvider
    p::P
    min_zoom::Int
    max_zoom::Int
    data_min::Float64
    data_max::Float64
    colorscheme::Symbol
    nodatacolor::RGB{Float64}
end
PyramidProvider(p::Pyramid, data_min, data_max; min_zoom=0, max_zoom=15, colorscheme=:viridis, nodatacolor=RGB{Float64}(1.0, 1.0, 1.0)) =
    PyramidProvider(p, min_zoom, max_zoom, data_min, data_max, colorscheme, nodatacolor)

function selectlevel_tile(pyramid, ext; target_imsize=(256, 256))
    pyrext = extent(pyramid)
    basepixels = map(pyrext, ext, size(pyramid)) do bbpyr, bbext, spyr
        pyrspan = bbpyr[2] - bbpyr[1]
        imsize = bbext[2] - bbext[1]
        imsize / pyrspan * spyr
    end
    dimlevels = log2.(basepixels ./ target_imsize)
    minlevel = minimum(dimlevels)
    n_agg = min(max(floor(Int, minlevel), 0), nlevels(pyramid))
    @debug "Selected level $n_agg"
    extcorrectnames = Extent{keys(pyrext)}(tuple(bounds(ext)...))
    levels(pyramid)[n_agg][extcorrectnames]
end


function Tyler.fetch_tile(p::PyramidProvider, tile::Tile)
    ext = extent(tile, wgs84)
    data = try
        selectlevel_tile(p.p, ext, target_imsize=(256, 256))
    catch e
        println("Error getting extent $ext")
        println(e)
        return fill(RGB{Float64}(1.0, 1.0, 1.0), 256, 256)
    end
    if isempty(data)
        return fill(RGB{Float64}(1.0, 1.0, 1.0), 256, 256)
    end
    ar = DimArray(data.data, data.axes)
    cs = colorschemes[p.colorscheme]
    inner_lon_step = (ext.X[2] - ext.X[1]) / 256
    inner_lat_step = (ext.Y[2] - ext.Y[1]) / 256
    inner_lons = range(ext.X..., length=257) .+ inner_lon_step / 2
    inner_lats = range(ext.Y..., length=257) .+ inner_lat_step / 2
    map(CartesianIndices((256:-1:1, 1:256))) do I
        ilat, ilon = I.I
        v = ar[lon=Near(inner_lons[ilon]), lat=Near(inner_lats[ilat])] |> only
        if isnan(v) || ismissing(v) || isinf(v)
            p.nodatacolor
        else
            cs[(v-p.data_min)/(p.data_max-p.data_min)]
        end
    end
end
TileProviders.max_zoom(p::PyramidProvider) = p.max_zoom
TileProviders.min_zoom(p::PyramidProvider) = p.min_zoom

function provider_request_handler(p::PyramidProvider)
    request -> begin
        k = request.target
        k = lstrip(k, '/')
        m = match(r"(\d+)/(\d+)/(\d+).png", k)
        if m === nothing
            return HTTP.Response(404, "Error: Malformed url")
        end
        z, x, y = tryparse.(Int, m.captures)
        any(isnothing, (x, y, z)) && return HTTP.Response(404, "Error: Malformed url")
        data = Tyler.fetch_tile(p, Tile(x, y, z))
        buf = IOBuffer()
        save(Stream{format"PNG"}(buf), data)
        return HTTP.Response(200, take!(buf))
    end
end
HTTP.serve(p::PyramidProvider, args...; kwargs...) = HTTP.serve(provider_request_handler(p), args...; kwargs...)
HTTP.serve!(p::PyramidProvider, args...; kwargs...) = HTTP.serve!(provider_request_handler(p), args...; kwargs...)
end


import TileProviders: TileProviders, AbstractProvider, Google
import HTTP, FileIO, DiskArrays
import Colors: RGB, FixedPointNumbers
struct MapTileDiskArray{T,P<:AbstractProvider} <: DiskArrays.ChunkTiledDiskArray{T,3}
    prov::P
    zoom::Int
end
MapTileDiskArray(prov, zoom) = MapTileDiskArray{FixedPointNumbers.N0f8,typeof(prov)}(prov, zoom)
DiskArrays.eachchunk(a::MapTileDiskArray) = DiskArrays.GridChunks((3, 256 * 2^a.zoom, 256 * 2^a.zoom), (3, 256, 256))
DiskArrays.haschunks(a::MapTileDiskArray) = DiskArrays.Chunked()

rgbeltype(::Type{RGB{T}}) where {T} = T
function Base.getindex(a::MapTileDiskArray, i::DiskArrays.ChunkIndex{<:Any,DiskArrays.OneBasedChunks})
    _, x, y = i.I.I
    url = TileProviders.geturl(a.prov, x, y, a.zoom)
    result = HTTP.get(url; retry=false, readtimeout=4, connect_timeout=4)
    io = IOBuffer(result.body)
    format = FileIO.query(io)
    data = FileIO.load(format)
    T = rgbeltype(eltype(data))
    data = reinterpret(reshape, T, data)
    return DiskArrays.wrapchunk(data, DiskArrays.eachchunk(a)[i.I])
end
# prov = Google()
# prov.options
# a = MapTileDiskArray(prov, 11);
# ind = ceil.(Int, size(a) ./ 256 ./ 2)

# a[DiskArrays.ChunkIndex(ind...)]

# import MapTiles: MapTiles, Tile, web_mercator, wgs84
# t = Tile(2000, 1024, 11)
# MapTiles.extent(t, wgs84)

# bands = [1, 3]
# x = 1000:1500
# y = 200:400