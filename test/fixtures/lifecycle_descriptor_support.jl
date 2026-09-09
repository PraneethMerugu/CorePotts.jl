function receipt_descriptor(
        index::Integer,
        effect::CorePotts.LifecycleEffectCode;
        domain_kind::Integer = 0,
        destination_kind::Integer = 0,
        parent_kind::Integer = 0,
        daughter_kind::Integer = 0,
        placement::CorePotts.LifecyclePlacementCode =
            CorePotts.NoLifecyclePlacement,
        placement_evaluator::Integer = 0,
        partition::CorePotts.LifecyclePartitionCode =
            CorePotts.NoLifecyclePartition,
        point_from_centroid::Bool = false,
        normal = (0.0, 0.0),
        relation_slot::Integer = 0,
        on_inadmissible::CorePotts.LifecycleInadmissibilityDisposition =
            CorePotts.ErrorLifecycleInadmissible,
        compiler_synthesized::Bool = false,
        cadence::CorePotts.LifecycleCadenceCode =
            CorePotts.EveryMCSLifecycleCadence,
        cadence_value::Integer = 1,
        state_rule_offset::Integer = 1,
        state_rule_count::Integer = 0,
        scalar_type::Type{<:AbstractFloat} = Float64,
    )
    T = scalar_type
    return CorePotts.LifecycleDescriptor{2, T}(
        Int32(index),
        UInt64(100 + index),
        UInt64(200 + index),
        effect === CorePotts.CreateCellLifecycleEffect ?
            CorePotts.ModelLifecycleDomain :
            CorePotts.CellKindLifecycleDomain,
        Int16(effect === CorePotts.CreateCellLifecycleEffect ? 0 : domain_kind),
        Int32(1),
        cadence,
        Int32(cadence_value),
        effect,
        Int32(0),
        on_inadmissible,
        Int16(destination_kind),
        Int16(1),
        placement,
        Int32(placement_evaluator),
        Int32(1),
        Int32(0),
        Int32(0),
        Int32(relation_slot),
        partition,
        Int32(0),
        point_from_centroid,
        (zero(T), zero(T)),
        Tuple(T.(normal)),
        CorePotts.CanonicalLifecycleSide,
        CorePotts.RNGOperationKey(),
        CorePotts.RNGOperationKey(),
        Int16(parent_kind),
        Int16(daughter_kind),
        Int32(state_rule_offset),
        Int32(state_rule_count),
        Int32(1),
        Int32(0),
        Int32(0),
        Int32(0),
        Int32(0),
        Int32(0),
        compiler_synthesized,
    )
end
