import yaml from "js-yaml";

/**
 * Robustly extracts every `node --test ...` shell invocation from a GitHub
 * Actions workflow's `run:` step scripts, returning the *exact* shell
 * argument tokens each invocation was called with.
 *
 * This exists because a naive "does the raw workflow text contain this
 * substring" (or even "does this raw multi-line block of text contain this
 * substring") check can't tell a real command-line argument apart from:
 *   - the same text appearing in a `#` shell comment,
 *   - the same text appearing as an argument to some other, earlier or
 *     later command (e.g. `echo tests/foo.mjs`) in the same `run:` script,
 *   - the same text appearing inside a quoted string that itself looks like
 *     a comment (`echo "# tests/foo.mjs"`),
 *   - a different file whose name merely contains the target path as a
 *     substring (`tests/foo.mjs.bak`, `other/tests/foo.mjs`), or
 *   - a command chained after a shell operator (`;`, `&&`, `||`, `|`, `&`)
 *     that is never part of the `node --test` invocation itself.
 *
 * To avoid those false positives this module actually parses the workflow
 * YAML (with js-yaml) and walks every job's steps looking for string `run:`
 * scripts, then tokenizes each script the way a POSIX shell would for the
 * purposes that matter here:
 *   - `\`-newline line continuations are resolved (both bare and inside
 *     double-quoted strings; single-quoted strings never interpret `\`),
 *   - `#` starts a comment only where a shell would actually start one
 *     (at the beginning of a word, i.e. not immediately after other word
 *     characters, and never inside a quoted string) and runs to the end of
 *     the physical line - a trailing `\` inside a comment does *not*
 *     continue the comment, matching real shell behavior,
 *   - single- and double-quoted words are dequoted (backslash escapes
 *     inside double quotes are resolved; single quotes are verbatim),
 *   - shell control operators (`;`, `&&`, `||`, `&`, `|`, `(`, `)`, and
 *     unescaped newlines) end the current simple command, and
 *   - simple redirections (`>`, `>>`, `<`, `<<`, with an optional leading
 *     fd number and `&fd` target, e.g. `2>&1`) are skipped rather than
 *     collected as arguments.
 *
 * Each resulting simple command whose first token is exactly `node` and
 * which contains the literal `--test` token is reported as an invocation,
 * with `tokens` holding every shell word in that command in order (dequoted,
 * comments and other commands excluded). Callers should check for exact
 * membership of a target test path in `tokens`, never a substring match
 * against reconstituted text.
 */

/**
 * Splits a shell script into an array of "simple commands", each itself an
 * array of dequoted word tokens, honoring quoting/escaping/line-continuation
 * and shell control operators as described above.
 */
export function tokenizeShellCommands(script) {
  const commands = [];
  let current = [];
  let word = null;

  const endWord = () => {
    if (word !== null) {
      current.push(word);
      word = null;
    }
  };
  const endCommand = () => {
    endWord();
    if (current.length > 0) commands.push(current);
    current = [];
  };

  const n = script.length;
  let i = 0;

  while (i < n) {
    const c = script[i];

    // `#` only starts a comment at the start of a word (i.e. nowhere inside
    // an in-progress word, and never inside a quote - those are handled by
    // dedicated branches below that never fall through to this check).
    if (c === "#" && word === null) {
      while (i < n && script[i] !== "\n") i += 1;
      continue;
    }

    if (c === "\\") {
      if (script[i + 1] === "\n") {
        // Unquoted line continuation: drop both characters, keep tokenizing
        // the same logical line/word.
        i += 2;
        continue;
      }
      const next = script[i + 1];
      word = (word ?? "") + (next ?? "");
      i += 2;
      continue;
    }

    if (c === "'") {
      // Single-quoted: fully verbatim, no escapes, until the closing quote.
      let j = i + 1;
      let buf = "";
      while (j < n && script[j] !== "'") {
        buf += script[j];
        j += 1;
      }
      word = (word ?? "") + buf;
      i = j + 1;
      continue;
    }

    if (c === '"') {
      // Double-quoted: backslash escapes its next char, and a backslash
      // immediately before a newline is a line continuation (removed).
      let j = i + 1;
      let buf = "";
      while (j < n && script[j] !== '"') {
        if (script[j] === "\\" && j + 1 < n) {
          if (script[j + 1] === "\n") {
            j += 2;
            continue;
          }
          buf += script[j + 1];
          j += 2;
          continue;
        }
        buf += script[j];
        j += 1;
      }
      word = (word ?? "") + buf;
      i = j + 1;
      continue;
    }

    if (c === ">" || c === "<") {
      // Redirection: consume the operator (and any doubled/`&`/`-` form)
      // plus an immediately-following `&<digits>` fd target (e.g. `2>&1`),
      // without recording any of it as a command argument. A leading fd
      // number that was being accumulated as `word` (e.g. the `2` in
      // `2>&1`) belongs to the redirection operator itself, not to an
      // argument, so it is discarded rather than pushed as a token. A
      // following filename target (rare in these workflows) is left for
      // the main loop to tokenize as an ordinary word, same as a real
      // shell would treat it as belonging to this same simple command.
      if (word !== null && /^[0-9]+$/.test(word)) {
        word = null;
      } else {
        endWord();
      }
      let j = i + 1;
      if (script[j] === c || script[j] === "&" || script[j] === "-") j += 1;
      if (script[j - 1] === "&") {
        while (j < n && /[0-9]/.test(script[j])) j += 1;
      }
      i = j;
      continue;
    }

    if (c === "&" && script[i + 1] === "&") {
      endCommand();
      i += 2;
      continue;
    }
    if (c === "|" && script[i + 1] === "|") {
      endCommand();
      i += 2;
      continue;
    }
    if (c === ";" && script[i + 1] === ";") {
      endCommand();
      i += 2;
      continue;
    }
    if (c === "|" || c === "&" || c === ";" || c === "(" || c === ")") {
      endCommand();
      i += 1;
      continue;
    }
    if (c === "\n") {
      endCommand();
      i += 1;
      continue;
    }

    if (/\s/.test(c)) {
      endWord();
      i += 1;
      continue;
    }

    word = (word ?? "") + c;
    i += 1;
  }
  endCommand();

  return commands;
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

/**
 * Parses a GitHub Actions workflow source and returns every `node --test`
 * invocation found in any job step's string `run:` script, as
 * `{ jobName, stepName, tokens }`, where `tokens` is the exact, in-order,
 * dequoted argument list of that single shell invocation (starting with
 * `"node"`), with comments, other commands, and redirections excluded.
 */
export function extractNodeTestInvocations(source) {
  const workflow = yaml.load(source);
  const invocations = [];

  if (!isPlainObject(workflow) || !isPlainObject(workflow.jobs)) {
    return invocations;
  }

  for (const [jobName, job] of Object.entries(workflow.jobs)) {
    if (!isPlainObject(job) || !Array.isArray(job.steps)) continue;

    for (const step of job.steps) {
      if (!isPlainObject(step) || typeof step.run !== "string") continue;

      const stepName = typeof step.name === "string" ? step.name : null;
      const commands = tokenizeShellCommands(step.run);

      for (const tokens of commands) {
        if (tokens[0] === "node" && tokens.includes("--test")) {
          invocations.push({ jobName, stepName, tokens });
        }
      }
    }
  }

  return invocations;
}

/** Exact-token membership check: `path` must be one whole shell word. */
export function invocationHasTestFile(invocation, path) {
  return invocation.tokens.includes(path);
}

/**
 * True when `invocation` pins `--test-concurrency=1` as the argument
 * immediately following `node --test`.
 */
export function invocationPinsConcurrency1(invocation) {
  return (
    invocation.tokens[0] === "node" &&
    invocation.tokens[1] === "--test" &&
    invocation.tokens[2] === "--test-concurrency=1"
  );
}
