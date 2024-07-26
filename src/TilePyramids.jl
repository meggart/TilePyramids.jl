module TilePyramids

using PyramidScheme: Pyramid, nlevels, levels, PyramidScheme
using ColorSchemes: colorschemes
using Colors: @colorant_str, RGB, FixedPointNumbers, RGBA
using Extents: Extent, bounds
using MapTiles: Tile, extent, wgs84, MapTiles, web_mercator
import Tyler
import DimensionalData: X, Y, Dim
using DimensionalData: Near, DimArray
using FileIO: Stream, @format_str, save, FileIO
import ImageMagick
import HTTP
import DiskArrays
import TileProviders: TileProviders, AbstractProvider, Google
export PyramidProvider, MapTileDiskArray, MapTileRGBDiskArray


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


"DiskArray representing maptiles as 3d arrays with bands"
struct MapTileDiskArray{T,N,P<:AbstractProvider} <: DiskArrays.ChunkTiledDiskArray{T,N}
    prov::P
    zoom::Int
    tilesize::Int
    nband::Int
end
function MapTileDiskArray(prov, zoom, mode=:band)
    testtile = load_data(prov,zoom,0,0)
    et = eltype(testtile)
    nband = if et <: RGB
        3
    elseif et <: RGBA
        4
    else
        error("Unknown color type $et")
    end
    if mode === :band
        return MapTileDiskArray{rgbeltype(et),3,typeof(prov)}(prov, zoom,size(testtile,1),nband)
    elseif mode === :rgb
        return MapTileDiskArray{et,2,typeof(prov)}(prov, zoom,size(testtile,1),nband)
    else
        error("Unknown mode $mode")
    end
end
DiskArrays.eachchunk(a::MapTileDiskArray{<:Any,3}) = DiskArrays.GridChunks((a.nband, a.tilesize * 2^a.zoom, a.tilesize * 2^a.zoom), (a.nband, a.tilesize, a.tilesize))
DiskArrays.eachchunk(a::MapTileDiskArray{<:Any,2}) = DiskArrays.GridChunks((a.tilesize * 2^a.zoom, a.tilesize * 2^a.zoom), (a.tilesize, a.tilesize))

DiskArrays.haschunks(a::MapTileDiskArray) = DiskArrays.Chunked()

rgbeltype(::Type{RGB{T}}) where {T} = T
rgbeltype(::Type{RGBA{T}}) where {T} = T
function Base.getindex(a::MapTileDiskArray{<:Any,3}, i::DiskArrays.ChunkIndex{3,DiskArrays.OneBasedChunks})
    _, y, x = i.I.I
    data = load_data(a.prov,a.zoom,x-1,y-1)
    T = rgbeltype(eltype(data))
    data = reinterpret(reshape, T, data)
    return DiskArrays.wrapchunk(data, DiskArrays.eachchunk(a)[i.I])
end

function Base.getindex(a::MapTileDiskArray{<:Any,2}, i::DiskArrays.ChunkIndex{2,DiskArrays.OneBasedChunks})
    y, x = i.I.I
    data = load_data(a.prov,a.zoom,x-1,y-1)
    return DiskArrays.wrapchunk(data, DiskArrays.eachchunk(a)[i.I])
end

function load_data(prov,zoom,x,y)
    url = TileProviders.geturl(prov, x, y, zoom)
    result = HTTP.get(url; retry=false, readtimeout=4, connect_timeout=4)
    if result.status > 300
        if result.status == 404
            return nothing
        else
            throw(ErrorException("HTTP error $(result.status)"))
        end
    else
        io = IOBuffer(result.body)
        format = FileIO.query(io)
        FileIO.load(format)
    end
end

function dimsfromzoomlevel(zoom,tilesize)
    t1 = Tile(1,1,zoom)
    ntiles = 2^zoom
    npix = ntiles*tilesize
    t2 = Tile(ntiles,ntiles,zoom)
    ex1 = MapTiles.extent(t1, web_mercator)
    ex2 = MapTiles.extent(t2, web_mercator)
    x1,x2 = first(ex1.X),last(ex2.X)
    y1,y2 = first(ex1.Y),last(ex2.Y)
    stepx = (x2-x1)/npix
    stepy = (y2-y1)/npix
    x = X(range(x1+stepx/2,x2-stepx/2,length=npix))
    y = Y(range(y1+stepy/2,y2-stepy/2,length=npix))
    return x,y
end
function provtoyax(prov,zoom,mode=:band)
    a = TilePyramids.MapTileDiskArray(prov, zoom, mode);
    xdim, ydim = dimsfromzoomlevel(zoom,a.tilesize)
    if mode === :band
        coldim = if a.nband == 3
            Dim{:Band}(["Red", "Green", "Blue"])
        elseif a.nband == 4
            Dim{:Band}(["Red", "Green", "Blue","Alpha"])
        end
        PyramidScheme.YAXArray((coldim, ydim, xdim), a)
    else
        PyramidScheme.YAXArray((ydim, xdim), a)
    end
end

function Pyramid(prov::TileProviders.Provider,mode=:band)
    maxzoom = get(prov.options,:max_zoom,18)
    base = provtoyax(prov,maxzoom,mode)
    levels = [provtoyax(prov,zoom,mode) for zoom in (maxzoom-1):-1:0]
    return Pyramid(base,levels,prov.options)
end

function Base.showable(::MIME"image/svg+xml", cs::PyramidScheme.YAXArray)
    false
  end

end #module