# Editable timeline vectors

`cut-titles-roles.json` is a worked example for the FCPXML 1.10 contract. The XPath goldens describe observable output so the Windows port can use the same vector without matching attribute order or whitespace. Change expected values by hand only when the documented interchange changes; record the reason here. The example keeps two two-second source ranges, crosses the cut with a title and caption, and loops a two-second music source starting one second in.

Apple's FCPXML 1.10 DTD is not redistributed here: Apple's published definition reserves all rights. Tests always check the document structure in this vector; set `VOXCLIP_FCPXML_DTD` to a locally obtained copy of the 1.10 DTD to also validate the document with Apple's definition.
