# Independent geometry from ownership coordinates, not maintained moment totals.
function independent_cell_center(ownership, owner::Int32)
    sites = findall(==(owner), ownership)
    isempty(sites) && return nothing
    return ntuple(2) do dimension
        sum(site[dimension] - 0.5 for site in sites) / length(sites)
    end
end

function independent_cell_length(ownership, owner::Int32)
    sites = findall(==(owner), ownership)
    isempty(sites) && return 0.0
    center = independent_cell_center(ownership, owner)
    covariance = zeros(Float64, 2, 2)
    for site in sites
        point = (site[1] - 0.5, site[2] - 0.5)
        displacement = (point[1] - center[1], point[2] - center[2])
        for row in 1:2, column in 1:2
            covariance[row, column] +=
                displacement[row] * displacement[column]
        end
    end
    covariance ./= length(sites)
    trace = covariance[1, 1] + covariance[2, 2]
    discriminant = max(
        0.0,
        (covariance[1, 1] - covariance[2, 2])^2 +
            4.0 * covariance[1, 2]^2,
    )
    largest = (trace + sqrt(discriminant)) / 2.0
    return 4.0 * sqrt(max(0.0, largest))
end
