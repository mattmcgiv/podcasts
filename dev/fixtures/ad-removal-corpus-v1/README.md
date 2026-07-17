# Ad-removal golden corpus format

This directory contains a synthetic, metadata-only example of the versioned
`pods-ad-removal-corpus-v1` format. It intentionally contains no real podcast
audio or transcript text.

Keep the real evaluation corpus outside this Git checkout. Create one local
directory containing:

- `corpus.json` with at least ten distinct episodes across at least five
  subscriptions;
- the original downloaded episode audio referenced by each `audio_file`;
- manually verified, non-overlapping `ad` and `content` second ranges;
- the stored transcript segment IDs; and
- the pipeline result with every skip's source segment IDs and whether Undo can
  reverse it.

All paths in `corpus.json` must be relative to the index directory. The loader
rejects absolute paths, `..` traversal, symlink escapes, missing files,
mismatched episode IDs, invalid time ranges, and overlapping labels.

Run the local gate with:

```sh
./dev/evaluate-ad-removal-corpus.sh /absolute/path/to/corpus.json
```

The command emits a JSON report. Exit status `0` means all gates passed, `2`
means the corpus was valid but missed a release threshold, `1` means the corpus
was invalid, and `64` means the command was used incorrectly. Passing requires
at least 95% of labeled ad seconds skipped, no more than 1% of labeled content
seconds skipped, complete segment traceability, and reversible false skips.
