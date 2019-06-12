# This file defines common logic for CUDAnative benchmarks.

using CUDAdrv, CUDAnative, NVTX, CuArrays

const MiB = 1 << 20
const naive_gc_config = GCConfiguration(local_arena_count=0, global_arena_initial_size=10 * MiB)
const opt_gc_config = GCConfiguration(local_arena_count=8, local_arena_initial_size=MiB, global_arena_initial_size=2 * MiB)

macro cuda(ex...)
    esc(quote
        if !haskey(ENV, "JULIA_GC")
            CUDAnative.@cuda $(ex...)
        elseif ENV["JULIA_GC"] == "BUMP"
            local capacity = 8 * MiB
            local buf = Mem.alloc(Mem.DeviceBuffer, capacity)
            local start_address = pointer(buf)
            local function init(kernel)
                CUDAnative.Runtime.bump_alloc_init!(kernel, start_address, capacity)
            end
            @sync CUDAnative.@cuda init=init malloc="ptx_bump_alloc" $(ex...)
            Mem.free(buf)
        elseif ENV["JULIA_GC"] == "NAIVE"
            CUDAnative.@cuda gc=true gc_config=naive_gc_config $(ex...)
        else
            CUDAnative.@cuda gc=true gc_config=opt_gc_config $(ex...)
        end
    end)
end
