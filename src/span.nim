## Source span representation: a byte-accurate location within a source file.
## Every compiler diagnostic is anchored to one of these.

type
  SourceLoc* = object
    path*: string      ## source file path as the user passed it
    line*: int         ## 1-based line number
    col*: int          ## 1-based byte column
    offset*: int       ## byte offset of the span start in the source
    length*: int       ## span length in bytes; 0 if unknown/unbounded

  ParseError* = ref object of ValueError
    ## Malformed input raised by the lexer and parser.  `parse` catches it,
    ## echoes a diagnostic, and returns nil so callers can abort cleanly.
    ## `msg` is inherited from `ValueError`; `loc` is the error span.
    loc*: SourceLoc

proc newSourceLoc*(path: string, source: string, offset: int, length: int = 0): SourceLoc =
  ## Compute line/col (1-based) by scanning `source` up to `offset`.
  ## `offset` is a byte index; newline bytes reset the line counter.
  ## If offset lies past the end of `source`, it is clamped to source.len.
  var o = offset
  if o > source.len:
    o = source.len
  if o < 0:
    o = 0
  var line = 1
  var col = 1
  for i in 0 ..< o:
    if source[i] == '\n':
      inc line
      col = 1
    else:
      inc col
  result = SourceLoc(path: path, line: line, col: col, offset: o, length: length)

proc sourceLocAt*(path: string, source: string, offset: int): SourceLoc =
  ## Convenience: a zero-length span rooted at `offset`.
  newSourceLoc(path, source, offset, 0)