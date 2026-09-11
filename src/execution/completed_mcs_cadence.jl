"""Pure membership law for completed-MCS boundaries, including explicit initialization capture."""
@enum CompletedMCSCadence::UInt8 begin
    EveryMCSCadence = 0x01
    AtMCSCadence = 0x02
    PeriodicMCSCadence = 0x03
end
@doc "Run at every positive completed MCS." EveryMCSCadence
@doc "Run at exactly the specified MCS; zero denotes explicit initialization." AtMCSCadence
@doc "Run at positive multiples of the specified positive period." PeriodicMCSCadence

function _validate_completed_mcs_cadence(cadence::CompletedMCSCadence, value::Integer; initialization::Bool = false)
    valid = !(value isa Bool) && (
        cadence === EveryMCSCadence ? value == 1 :
            cadence === AtMCSCadence ? value >= (initialization ? 0 : 1) : value > 0
    )
    valid || throw(
        ArgumentError(
            "completed-MCS cadence requires one for every-MCS, a $(initialization ? "nonnegative" : "positive") exact boundary, or a positive period"
        )
    )
    return nothing
end

@inline function _completed_mcs_due(cadence::CompletedMCSCadence, value::Integer, mcs::Integer)
    cadence === EveryMCSCadence && return mcs > 0
    cadence === AtMCSCadence && return mcs == value
    cadence === PeriodicMCSCadence && return mcs > 0 && rem(mcs, value) == 0
    return false
end
