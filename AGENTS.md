# Project Rules

## Commits

- Use Conventional Commits for every commit in this repository.
- Format commit subjects as `<type>(<scope>): <description>` or `<type>: <description>`.
- Prefer these types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`, `revert`.
- Keep the description imperative, concise, and lowercase unless it contains a proper noun.
- Use an optional scope when it clarifies the touched area, for example `feat(parser): attach image assets`.
- Use `!` after the type or scope for breaking changes, and include a `BREAKING CHANGE:` footer when applicable.
- Add a body when the reason, migration notes, or behavioral impact are not obvious from the subject.

Examples:

- `feat(parser): support quoted context asset paths`
- `fix(rpc): sanitize app-server malloc environment`
