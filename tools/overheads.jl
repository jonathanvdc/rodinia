include("common.jl")
include("measure.jl")

host = gethostname()
measure(host)
data = summarize(CSV.read("measurements_$host.dat"))
data = filter(d -> d[:target] != "#host", data)
data = by(data, [:suite, :benchmark, :config]) do df
    mins = by(df, [:target]) do d
        DataFrame(time = minimum(d[:time]))
    end
    DataFrame(time = sum(mins[:time]))
end
data = by(data, [:suite, :benchmark]) do df
    function get_result(name)
        first(filter(d -> d[:config] == name, df))[:time].val
    end
    DataFrame(
        nogc = get_result("NONE"),
        gc = get_result("OPT"),
        shared_gc = get_result("NAIVE"),
        bump = get_result("BUMP"),
        nogc_ratio = 1.0,
        gc_ratio = get_result("OPT") / get_result("NONE"),
        shared_gc_ratio = get_result("NAIVE") / get_result("NONE"),
        bump_ratio = get_result("BUMP") / get_result("NONE"))
end
sort!(data, [order(:nogc)])

CSV.write("crunched_data.csv", data)
println(data)
