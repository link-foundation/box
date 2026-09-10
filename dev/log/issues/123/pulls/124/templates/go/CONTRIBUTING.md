# Contributing to Go AI-Driven Development Pipeline Template

Thank you for considering contributing to this project! This document outlines the development workflow and standards.

## Development Setup

### Prerequisites

- Go 1.21 or later
- Bun (for running scripts)
- Git
- pre-commit (optional, but recommended)

### Getting Started

1. Fork and clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/go-ai-driven-development-pipeline-template.git
   cd go-ai-driven-development-pipeline-template
   ```

2. Install pre-commit hooks (optional but recommended):
   ```bash
   pip install pre-commit
   pre-commit install
   ```

3. Verify the setup:
   ```bash
   go test ./...
   go build ./...
   ```

## Code Quality Standards

### Formatting

All Go code must be formatted with `gofmt`:

```bash
gofmt -w .
```

### Linting

We use `go vet` and `staticcheck` for linting:

```bash
go vet ./...
staticcheck ./...
```

### Testing

All features require tests. We use the standard Go testing framework:

```bash
# Run all tests
go test ./...

# Run with race detection
go test -race ./...

# Run with coverage
go test -cover ./...
```

### File Size Limits

Keep files under 1000 lines to encourage modular design:

```bash
bun scripts/check-file-size.mjs
```

## Making Changes

### Branch Naming

Use descriptive branch names:
- `feature/add-new-function`
- `fix/resolve-race-condition`
- `docs/update-readme`

### Commit Messages

Write clear, concise commit messages:
- Use imperative mood: "Add feature" not "Added feature"
- Keep the first line under 72 characters
- Add a blank line before any additional details

Example:
```
Add Multiply function for integer multiplication

- Implements integer and float variants
- Includes comprehensive test coverage
- Updates documentation with usage examples
```

### Changesets

When making changes that should be documented, create a changeset file in `.changeset/`:

1. Create a new markdown file with a descriptive name:
   ```bash
   touch .changeset/my-awesome-feature.md
   ```

2. Add content in the changeset format:
   ```markdown
   ---
   'go-ai-driven-development-pipeline-template': minor
   ---

   Added new awesome feature that does X, Y, and Z.
   ```

3. Choose the appropriate version bump:
   - `patch` - Bug fixes and minor changes (0.0.x)
   - `minor` - New features, backwards compatible (0.x.0)
   - `major` - Breaking changes (x.0.0)

See `.changeset/README.md` for more details.

## Pull Request Process

1. Ensure all tests pass locally:
   ```bash
   go test -race ./...
   go vet ./...
   gofmt -l .
   ```

2. Create a changeset file if your changes affect functionality

3. Push your branch and create a pull request

4. Wait for CI checks to pass

5. Address any review feedback

6. Merge after approval

## Code Style Guidelines

### Documentation

- All exported functions must have doc comments
- Use complete sentences starting with the function name
- Include examples for complex functions

```go
// Add returns the sum of two integers.
// It handles both positive and negative numbers.
func Add(a, b int) int {
    return a + b
}
```

### Error Handling

- Return errors instead of panicking
- Wrap errors with context when appropriate
- Check errors explicitly

```go
func DoSomething() error {
    result, err := someOperation()
    if err != nil {
        return fmt.Errorf("operation failed: %w", err)
    }
    return nil
}
```

### Naming Conventions

- Use camelCase for unexported identifiers
- Use PascalCase for exported identifiers
- Avoid abbreviations unless widely understood (e.g., `ctx` for context)
- Name receivers with short, consistent names

### Testing Patterns

Use table-driven tests for comprehensive coverage:

```go
func TestAdd(t *testing.T) {
    tests := []struct {
        name     string
        a, b     int
        expected int
    }{
        {"positive numbers", 2, 3, 5},
        {"with zero", 5, 0, 5},
        {"negative numbers", -2, -3, -5},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            result := Add(tt.a, tt.b)
            if result != tt.expected {
                t.Errorf("Add(%d, %d) = %d; want %d",
                    tt.a, tt.b, result, tt.expected)
            }
        })
    }
}
```

## Running CI Locally

Before pushing, run the full CI check locally:

```bash
# Format check
test -z "$(gofmt -l .)"

# Linting
go vet ./...
staticcheck ./...

# Tests with race detection
go test -race ./...

# File size check
bun scripts/check-file-size.mjs

# Build verification
go build ./...
```

## Release Process

Releases are automated through GitHub Actions using the changeset workflow:

### Automatic Releases

1. Create a PR with your changes
2. Include a changeset file describing your changes
3. When the PR is merged to main, the version is automatically bumped based on the changeset
4. A new GitHub release is created

### Manual Releases

Maintainers can trigger a release manually:

1. Go to Actions > CI/CD Pipeline
2. Click "Run workflow"
3. Select the release mode:
   - `instant` - Immediate release with specified bump type
   - `changeset` - Process existing changesets in the repository

## Questions?

Feel free to open an issue for any questions or concerns about contributing.
