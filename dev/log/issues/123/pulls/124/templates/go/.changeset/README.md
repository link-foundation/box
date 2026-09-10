# Changesets

This folder contains changeset files that describe changes to the project. Each changeset file represents a single change or set of related changes.

## Creating a Changeset

When making changes that should be documented, create a new markdown file in this directory with a random name (e.g., `happy-dogs-dance.md`).

### Changeset Format

```markdown
---
'go-ai-driven-development-pipeline-template': patch
---

Your description of the changes here.
```

### Version Types

- **patch**: Bug fixes and minor changes (0.0.x)
- **minor**: New features, backwards compatible (0.x.0)
- **major**: Breaking changes (x.0.0)

## Example

File: `.changeset/brave-cats-sing.md`

```markdown
---
'go-ai-driven-development-pipeline-template': minor
---

Added new Multiply and MultiplyFloat functions for arithmetic operations.
```

## How It Works

1. Create a changeset file when you make changes
2. Include the changeset in your pull request
3. During release, changesets are merged and version is bumped automatically
4. Changeset files are deleted after the version is bumped

## Benefits

- **No merge conflicts**: Each PR has its own changeset file
- **Per-PR documentation**: Changes are documented at the time they're made
- **Automated releases**: Changesets trigger automatic version bumps
- **Safe version management**: Version bumps happen after PR merge, preventing conflicts
