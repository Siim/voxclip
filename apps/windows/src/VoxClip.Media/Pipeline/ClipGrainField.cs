using System.Buffers;
using VoxClip.Core.Domain.Clips;

namespace VoxClip.Media.Pipeline;

/// <summary>One rendered frame's grain (looks spec §5.7; Core <see cref="ClipGrain"/>): every cell's PCG value computed once, about
/// half a million cells at 1080 × 1920, then each pixel's exact integer total from its four cells with weights in quarters
/// (9/3/3/1 on 2-pixel cells). The totals equal <see cref="ClipGrain.Total"/> at every pixel.</summary>
internal sealed class ClipGrainField : IDisposable
{
    private readonly int[] cells;
    private readonly int columns;
    private readonly int[] cellColumn;
    private readonly int[] weightX;
    private readonly int[] cellRow;
    private readonly int[] weightY;

    /// <summary>The cells of a <paramref name="width"/> × <paramref name="height"/> frame with the frame hash
    /// <paramref name="frameHash"/> (<see cref="ClipGrain.FrameHash"/>).</summary>
    internal ClipGrainField(int width, int height, uint frameHash, CancellationToken ct = default)
    {
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(width);
        ArgumentOutOfRangeException.ThrowIfNegativeOrZero(height);
        cellColumn = new int[width];
        weightX = new int[width];
        for (var x = 0; x < width; x++) (cellColumn[x], _, weightX[x], _) = ClipGrain.CellAt(x, 0, width, height);
        cellRow = new int[height];
        weightY = new int[height];
        for (var y = 0; y < height; y++) (_, cellRow[y], _, weightY[y]) = ClipGrain.CellAt(0, y, width, height);
        // Cells grow with the pixel, so the grid spans the first pixel's cell to one past the last pixel's.
        var firstColumn = cellColumn[0];
        var firstRow = cellRow[0];
        columns = cellColumn[^1] + 2 - firstColumn;
        var rows = cellRow[^1] + 2 - firstRow;
        for (var x = 0; x < width; x++) cellColumn[x] -= firstColumn;
        for (var y = 0; y < height; y++) cellRow[y] -= firstRow;
        var grid = cells = ArrayPool<int>.Shared.Rent(checked(columns * rows));
        var count = columns;
        try
        {
            Parallel.For(0, rows, new ParallelOptions { CancellationToken = ct }, row =>
            {
                var rowHash = ClipGrain.Pcg(unchecked((uint)(row + firstRow) + frameHash));
                var start = row * count;
                for (var column = 0; column < count; column++)
                    grid[start + column] = (int)(ClipGrain.Pcg(unchecked((uint)(column + firstColumn) + rowHash)) >> 16) - 32768;
            });
        }
        catch { ArrayPool<int>.Shared.Return(grid); throw; }
    }

    /// <summary>Row <paramref name="y"/>'s totals, one per pixel, within ±2^19; grain is total / 2^20.</summary>
    internal void Row(int y, Span<int> totals)
    {
        var top = cellRow[y] * columns;
        var bottom = top + columns;
        var fy = weightY[y];
        var grid = cells;
        for (var x = 0; x < totals.Length; x++)
        {
            var i = cellColumn[x];
            var fx = weightX[x];
            totals[x] = ((4 - fx) * grid[top + i] + fx * grid[top + i + 1]) * (4 - fy) + ((4 - fx) * grid[bottom + i] + fx * grid[bottom + i + 1]) * fy;
        }
    }

    /// <inheritdoc />
    public void Dispose() => ArrayPool<int>.Shared.Return(cells);
}
