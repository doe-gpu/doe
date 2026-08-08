# Status policy

Live status files contain only:

- the current promoted boundary;
- active blockers;
- source-of-truth artifact pointers;
- one history pointer.

They do not contain dated chronology, copied benchmark results, hashes, pass
counts, or closed implementation notes. Move resolved narrative into
`archive/` in the same change that updates the live boundary.

Artifacts remain authoritative. Archive files may receive link and formatting
repairs but should preserve historical meaning.
