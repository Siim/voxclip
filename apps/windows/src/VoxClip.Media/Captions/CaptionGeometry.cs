using SkiaSharp;
using VoxClip.Core.Domain.Captions;
using VoxClip.Core.Domain.Shared;

namespace VoxClip.Media.Captions;

internal static class CaptionGeometry
{
    internal readonly record struct RoundedCommand(char Verb, double First = 0, double Second = 0, double Third = 0, double Fourth = 0, double Fifth = 0, double Sixth = 0)
    {
        internal int ValueCount => Verb == 'Z' ? 0 : Verb == 'C' ? 6 : 2;
        internal double this[int index] => index switch { 0 => First, 1 => Second, 2 => Third, 3 => Fourth, 4 => Fifth, 5 => Sixth, _ => throw new ArgumentOutOfRangeException(nameof(index)) };
    }

    internal static void Rounded(SKPath path, double left, double top, double width, double height, double radius)
    {
        Span<RoundedCommand> commands = stackalloc RoundedCommand[10];
        var count = RoundedCommands(left, top, width, height, radius, commands);
        for (var index = 0; index < count; index++)
        {
            var command = commands[index];
            switch (command.Verb)
            {
                case 'M': path.MoveTo((float)command[0], (float)command[1]); break;
                case 'L': path.LineTo((float)command[0], (float)command[1]); break;
                case 'C': path.CubicTo((float)command[0], (float)command[1], (float)command[2], (float)command[3], (float)command[4], (float)command[5]); break;
                case 'Z': path.Close(); break;
            }
        }
    }

    internal static int RoundedCommands(double left, double top, double width, double height, double radius, Span<RoundedCommand> commands)
    {
        var right = left + width;
        var bottom = top + height;
        radius = Math.Min(radius, Math.Min(width / 2, height / 2));
        if (radius <= 0)
        {
            commands[0] = new('M', left, top); commands[1] = new('L', right, top);
            commands[2] = new('L', right, bottom); commands[3] = new('L', left, bottom); commands[4] = new('Z');
            return 5;
        }
        var control = 0.5522847498 * radius;
        commands[0] = new('M', left + radius, top); commands[1] = new('L', right - radius, top);
        commands[2] = new('C', right - radius + control, top, right, top + radius - control, right, top + radius);
        commands[3] = new('L', right, bottom - radius); commands[4] = new('C', right, bottom - radius + control, right - radius + control, bottom, right - radius, bottom);
        commands[5] = new('L', left + radius, bottom); commands[6] = new('C', left + radius - control, bottom, left, bottom - radius + control, left, bottom - radius);
        commands[7] = new('L', left, top + radius); commands[8] = new('C', left, top + radius - control, left + radius - control, top, left + radius, top);
        commands[9] = new('Z');
        return 10;
    }

    internal static (SKPoint Start, SKPoint End) Gradient(double left, double top, double width, double height, double degrees)
    {
        var endpoints = GradientPoints(left, top, width, height, degrees);
        return (new((float)endpoints.Start.X, (float)endpoints.Start.Y), new((float)endpoints.End.X, (float)endpoints.End.Y));
    }

    internal static (PointD Start, PointD End) GradientPoints(double left, double top, double width, double height, double degrees)
    {
        var radians = degrees * Math.PI / 180;
        var directionX = Math.Cos(radians);
        var directionY = Math.Sin(radians);
        var half = width / 2 * Math.Abs(directionX) + height / 2 * Math.Abs(directionY);
        return (new(left + width / 2 - directionX * half, top + height / 2 - directionY * half),
            new(left + width / 2 + directionX * half, top + height / 2 + directionY * half));
    }
}
