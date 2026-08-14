import assert from "node:assert/strict";
import test from "node:test";
import * as React from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { sourceLabel, UpdateNotice } from "./home-view";

test("sourceLabel maps each ActiveAgent source to its display label", () => {
  assert.equal(sourceLabel("both"), "Process + session");
  assert.equal(sourceLabel("process"), "Process");
  assert.equal(sourceLabel("session"), "Session");
});

test("UpdateNotice is compact notify-only release copy with view and recheck actions", () => {
  const markup = renderToStaticMarkup(
    React.createElement(UpdateNotice, {
      availableVersion: "v1.2.0",
      checking: false,
      onView: () => undefined,
      onCheck: () => undefined,
    }),
  );

  assert.match(markup, /Seer v1\.2\.0 is available/);
  assert.match(markup, /View release/);
  assert.match(markup, /Check again/);
  assert.doesNotMatch(markup, /download|install/i);
});
