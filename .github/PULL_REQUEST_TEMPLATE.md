<!--
The title takes the form of a commit subject, because the merge uses it:
`type: summary`, in the imperative, under 60 characters.
-->

## What changed

<!--
Open with a paragraph only where a reader would otherwise ask why this is one
pull request. Then one bullet per change, naming the function, the assertion or
the message it touches.
-->

-

## How it was checked

<!--
The output of `make check`. Name anything you could not check here and say why,
so a reviewer knows what CI is carrying.
-->

## Checklist

- [ ] `make check` passes.
- [ ] A line under `Unreleased` in `CHANGELOG.md` for a change a user would notice.
- [ ] New tests sit in their group and read as `area: case -> expectation`.
