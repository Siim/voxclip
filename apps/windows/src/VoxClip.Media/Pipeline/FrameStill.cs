using VoxClip.Core.Domain.Clips;

namespace VoxClip.Media.Pipeline;

/// <summary>What a Picture still composes (looks spec §7): the export's frame, or with <paramref name="BeforeGrade"/> only the framed
/// picture before the grade (orientation, crop, lip-synced picture, context demo and illustration), the frame Picture's look tiles
/// start from. <paramref name="Colour"/>'s look, adjustments and grade replace the clip's; its other controls are ignored.</summary>
/// <param name="BeforeGrade">Stop before the grade.</param>
/// <param name="Colour">The colour state to render; null keeps the clip's.</param>
internal readonly record struct FrameStill(bool BeforeGrade, ProjectClipControls? Colour);
