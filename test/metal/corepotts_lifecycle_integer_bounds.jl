using Test
import CorePotts
import Metal
import KernelAbstractions
using KernelAbstractions: @kernel, @index

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "lifecycle_integer_bounds_support.jl"))

@kernel function lifecycle_conversion_guard!(result, values, ::Type{T}) where {T}
    i = @index(Global, Linear)
    @inbounds result[i] = CorePotts._lifecycle_value_convertible(T, values[i])
end

@testset "lifecycle integer conversion bounds on Metal" begin
    Metal.functional() || error("lifecycle integer conversion requires functional Metal")
    Metal.allowscalar(false)
    # Direct primitive checks do not imply that Int8 is an admitted state bank.
    for target_type in (Int8, Int32, UInt32, Bool)
        values = lifecycle_conversion_inputs(target_type, Float32)
        device_values = Metal.MtlArray(values)
        result = Metal.MtlArray(fill(false, length(values)))
        backend = KernelAbstractions.get_backend(result)
        lifecycle_conversion_guard!(backend, 32)(result, device_values, target_type; ndrange = length(values))
        KernelAbstractions.synchronize(backend)
        @test Array(result) == lifecycle_conversion_oracle(target_type, values)
    end
    test_lifecycle_integer_bounds(
        CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray,
        target_types = (Int32, UInt32),
    )
end
