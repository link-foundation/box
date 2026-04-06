# Programming Language Rankings Data Collection

This directory contains scripts to collect, normalize, and aggregate programming language popularity data from multiple reliable sources.

## Overview

The goal is to create a scientifically weighted ranking of programming languages that can be regularly updated and used as a decision-making tool for selecting languages to include in the box Docker image.

## Data Sources

| Source | URL | Data Origin | Update Frequency | Weight |
|--------|-----|-------------|------------------|--------|
| **GitHut** | [madnight.github.io/githut](https://madnight.github.io/githut/) | GitHub Archive (BigQuery) | Quarterly | 35% |
| **TIOBE** | [tiobe.com/tiobe-index](https://www.tiobe.com/tiobe-index/) | Search engine queries | Monthly | 25% |
| **PYPL** | [pypl.github.io/PYPL.html](https://pypl.github.io/PYPL.html) | Google Trends | Monthly | 20% |
| **Stack Overflow** | [survey.stackoverflow.co](https://survey.stackoverflow.co/) | Developer Survey | Yearly | 20% |

### Source Details

#### GitHut (35% weight)
- **Data**: Pull requests, push events, star events, issue events from GitHub
- **Strengths**: Actual code activity, largest sample size, real project usage
- **Weaknesses**: Bias toward open source, over-represents web technologies
- **Raw Data**: JSON files from [github.com/madnight/githut](https://github.com/madnight/githut)

#### TIOBE Index (25% weight)
- **Data**: Search engine query frequency analysis
- **Strengths**: Long history (since 2001), global coverage, independent of GitHub
- **Weaknesses**: Measures interest rather than usage, can be influenced by SEO
- **Raw Data**: CSV files from [community-maintained repository](https://github.com/toUpperCase78/tiobe-index-ratings)

#### PYPL - PopularitY of Programming Language (20% weight)
- **Data**: Google Trends tutorial search frequency
- **Strengths**: Good indicator of learning intent, tracks emerging languages
- **Weaknesses**: Only measures learning intent, regional bias
- **Raw Data**: JavaScript data files from [github.com/pypl/pypl.github.io](https://github.com/pypl/pypl.github.io)

#### Stack Overflow Developer Survey (20% weight)
- **Data**: Self-reported usage from annual developer survey
- **Strengths**: Direct developer feedback, includes sentiment (admired/desired)
- **Weaknesses**: Selection bias, English-speaking bias, yearly updates only
- **Raw Data**: Survey results from [survey.stackoverflow.co](https://survey.stackoverflow.co/)

## Usage

### Prerequisites

```bash
# Node.js 18+ required (with fetch support)
node --version
```

> **Note**: No `npm install` is required. Scripts that need npm packages use [use-m](https://github.com/link-foundation/use-m) for dynamic loading at runtime.

### Fetch All Data

```bash
# Run the master script to fetch all sources and aggregate
node scripts/language-tops/fetch-all.mjs
```

### Run Individual Scripts

```bash
# Fetch PYPL data
node scripts/language-tops/fetch-pypl.mjs

# Fetch TIOBE data
node scripts/language-tops/fetch-tiobe.mjs

# Fetch GitHut data
node scripts/language-tops/fetch-githut.mjs

# Fetch Stack Overflow data
node scripts/language-tops/fetch-stackoverflow.mjs

# Aggregate all sources
node scripts/language-tops/aggregate.mjs
```

## Output

All data is saved to the `data/` directory:

| File | Description |
|------|-------------|
| `pypl.json` | PYPL language rankings with historical data |
| `tiobe.json` | TIOBE index rankings with historical data |
| `githut.json` | GitHut rankings from GitHub activity metrics |
| `stackoverflow.json` | Stack Overflow survey results |
| `aggregated.json` | Combined weighted rankings |
| `aggregated.lino` | Rankings in links-notation format |

### Output Format

```json
{
  "meta": {
    "title": "Aggregated Programming Language Rankings",
    "generatedAt": "2026-01-10T12:00:00.000Z"
  },
  "methodology": {
    "weights": {
      "githut": { "weight": 0.35, "description": "GitHub Activity" },
      "tiobe": { "weight": 0.25, "description": "Search Engine Queries" },
      "pypl": { "weight": 0.20, "description": "Tutorial Searches" },
      "stackoverflow": { "weight": 0.20, "description": "Developer Survey" }
    }
  },
  "rankings": [
    {
      "rank": 1,
      "name": "Python",
      "score": 0.187,
      "scorePercent": "18.70%",
      "confidence": 1.0,
      "sources": { ... }
    }
  ]
}
```

## Weighting Methodology

The weights are determined by:

1. **Sample Size**: Larger datasets receive more weight
2. **Update Frequency**: More frequently updated sources are more current
3. **Methodology Relevance**: Direct usage measurement vs. proxy indicators
4. **Independence**: Sources measuring different aspects reduce correlation bias

The aggregation uses a **weighted average** approach where each language's final score is:

```
finalScore = Σ (source_score × source_weight) / Σ source_weight
```

A **confidence score** is also calculated based on how many sources include each language.

## Updating Data

To keep rankings current, run the fetch scripts regularly:

- **Monthly**: TIOBE and PYPL data updates
- **Quarterly**: GitHut data updates
- **Yearly**: Stack Overflow survey (typically released mid-year)

### Automation

Add to crontab for automatic updates:

```bash
# Update monthly on the 1st at 3:00 AM
0 3 1 * * cd /path/to/box && node scripts/language-tops/fetch-all.mjs >> /var/log/language-rankings.log 2>&1
```

## Links-Notation Integration

The aggregation script outputs data in links-notation format, enabling integration with the [links-notation](https://github.com/link-foundation/links-notation) ecosystem.

```bash
node scripts/language-tops/aggregate.mjs
# Creates data/aggregated.lino

# Validate the lino file (uses use-m for dynamic dependency loading)
node scripts/language-tops/validate-lino.mjs
```

## Contributing

To add a new data source:

1. Create `fetch-<source>.mjs` in this directory
2. Follow the existing script structure
3. Output JSON with `rankings` array containing `{ name, share, rank }`
4. Add source weight in `aggregate.mjs`
5. Update this README

## License

MIT License - see [LICENSE](../../LICENSE) for details.
