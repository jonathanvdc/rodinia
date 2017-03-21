const BLOCK_SIZE = 16
const MATRIX_SIZE = BLOCK_SIZE * BLOCK_SIZE

using CUDAdrv, CUDAnative

function lud_diagonal(matrix_ptr, matrix_dim, offset)
    matrix = CuDeviceArray((matrix_dim, matrix_dim), matrix_ptr)
    shadow = @cuStaticSharedMem(Float32, (BLOCK_SIZE,BLOCK_SIZE))

    tx = threadIdx().x

    for i = 1:BLOCK_SIZE
        shadow[tx, i] = matrix[offset + tx, offset+i]
    end

    sync_threads()

    for i = 1:BLOCK_SIZE-1
        if tx > i
            for j = 1:i-1
                shadow[i, tx] -= shadow[j, tx] * shadow[i, j]
            end
            shadow[i, tx] /= shadow[i, i]
        end

        sync_threads()

        if tx > i
            for j = 1:i
                shadow[tx, i + 1] -= shadow[j, i + 1] * shadow[tx, j]
            end
        end

        sync_threads()
    end

    # The first row is not modified, it is no need to write it back to the global memory.
    for i = 2:BLOCK_SIZE
        matrix[offset + tx, offset + i] = shadow[tx, i]
    end

    return nothing
end

function lud_perimeter(matrix_ptr, matrix_dim, offset)
    matrix = CuDeviceArray((matrix_dim, matrix_dim), matrix_ptr)
    dia = @cuStaticSharedMem(Float32, (BLOCK_SIZE,BLOCK_SIZE))
    peri_row = @cuStaticSharedMem(Float32, (BLOCK_SIZE,BLOCK_SIZE))
    peri_col = @cuStaticSharedMem(Float32, (BLOCK_SIZE,BLOCK_SIZE))

    # FIXME: typecast because otherwise `index` isn't inferred correctly,
    #        probably because of JuliaLang/#15276
    bx = Int(blockIdx().x)
    tx = Int(threadIdx().x)

    # FIXME: for some strange reason having bounds checking on the accesses below
    #        introduces diverging results (even though non actually go out of bounds...)
    if tx <= BLOCK_SIZE
        index = tx

        for i = 1:BLOCK_SIZE÷2
            @inbounds dia[index, i] = matrix[offset+index, offset+i]
        end

        for i = 1:BLOCK_SIZE
            @inbounds peri_row[index, i] = matrix[offset + index + bx * BLOCK_SIZE, offset + i]
        end
    else
        index = tx - BLOCK_SIZE

        for i = 1+BLOCK_SIZE÷2:BLOCK_SIZE
            @inbounds dia[index, i] = matrix[offset + index, offset + i]
        end

        for i = 1:BLOCK_SIZE
            @inbounds peri_col[index, i] = matrix[offset + index, offset + i + bx * BLOCK_SIZE]
        end
    end

    sync_threads()

    if tx <= BLOCK_SIZE # peri-row
        index = tx
        for i = 2:BLOCK_SIZE, j = 1:i-1
            peri_row[index, i] -= dia[j, i] * peri_row[index, j]
        end
    else # peri-col
        index = tx - BLOCK_SIZE
        for i = 1:BLOCK_SIZE
            for j = 1:i-1
                peri_col[i, index] -= peri_col[j, index] * dia[i, j]
            end
            peri_col[i, index] /= dia[i, i]
        end
    end

    sync_threads()

    if tx <= BLOCK_SIZE # peri-row
        index = tx
        for i = 2:BLOCK_SIZE
            matrix[offset + index + bx * BLOCK_SIZE, offset + i] = peri_row[index, i]
        end
    else # peri-col
        index = tx - BLOCK_SIZE
        for i = 1:BLOCK_SIZE
            matrix[offset + index, offset + bx * BLOCK_SIZE + i] = peri_col[index, i]
        end
    end

    return nothing
end

function lud_internal(matrix_ptr, matrix_dim, offset)
    matrix = CuDeviceArray((matrix_dim, matrix_dim), matrix_ptr)
    peri_col = @cuStaticSharedMem(Float32, (BLOCK_SIZE,BLOCK_SIZE))
    peri_row = @cuStaticSharedMem(Float32, (BLOCK_SIZE,BLOCK_SIZE))

    global_row_id = offset + blockIdx().y * BLOCK_SIZE
    global_col_id = offset + blockIdx().x * BLOCK_SIZE

    tx = threadIdx().x
    ty = threadIdx().y

    peri_row[tx, ty] = matrix[global_col_id + tx, offset + ty]
    peri_col[tx, ty] = matrix[offset + tx, global_row_id + ty]

    sync_threads()

    sum = 0f0
    for i = 1:BLOCK_SIZE
        sum += peri_col[i, ty] * peri_row[tx, i]
    end
    matrix[global_col_id + tx, global_row_id + ty] -= sum

    return nothing
end

function lud_cuda(dev, matrix, matrix_dim)
    i = 0
    while i < matrix_dim - BLOCK_SIZE
        @cuda (1, BLOCK_SIZE) lud_diagonal(pointer(matrix), matrix_dim, i)

        grid_size = (matrix_dim-i)÷BLOCK_SIZE - 1

        @cuda (grid_size, BLOCK_SIZE * 2) lud_perimeter(pointer(matrix), matrix_dim, i)

        @cuda ((grid_size, grid_size), (BLOCK_SIZE, BLOCK_SIZE)) lud_internal(
            pointer(matrix), matrix_dim, i)

        i += BLOCK_SIZE
    end

    @cuda (1, BLOCK_SIZE) lud_diagonal(pointer(matrix), matrix_dim, i)
end
