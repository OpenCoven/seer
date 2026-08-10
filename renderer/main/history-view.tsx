import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Bot, Coffee, History as HistoryIcon, Trash2 } from "lucide-react";
import type { ReactNode } from "react";

import { useRendererBridge } from "../bridge/renderer-bridge-context";
import type { AwakeSession } from "../bridge/types";
import { PanelTabs } from "../components/panel-tabs";
import { EMPTY_STATS, formatDuration, formatSessionTime, sessionAgentNames } from "../lib/history";
import { Button, EmptyState, List, ScrollPanel, Text, Toolbar, ToolbarActions, ToolbarContent } from "../ui/primitives";
import { useAppSnapshot, writeAppSnapshot } from "./root-view";

function StatTile({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex min-w-0 flex-col gap-0.5 rounded-xl bg-control-subtle px-3 py-2.5">
      <Text variant="large-strong" className="tabular-nums" truncate>
        {value}
      </Text>
      <Text variant="mini" color="tertiary">
        {label}
      </Text>
    </div>
  );
}

function SectionLabel({ children }: { children: ReactNode }) {
  return (
    <Text variant="small-strong" color="secondary">
      {children}
    </Text>
  );
}

export function HistoryView() {
  const bridge = useRendererBridge();
  const queryClient = useQueryClient();
  const { data: snapshot } = useAppSnapshot();
  const stats = snapshot?.history ?? EMPTY_STATS;

  const clearMutation = useMutation({
    mutationFn: () => bridge.clearHistory(),
    onSuccess: (next) => writeAppSnapshot(queryClient, next),
  });

  const handleQuit = () => {
    void bridge.quit();
  };

  const hasHistory =
    stats.totalAwakeMs > 0 || stats.recentSessions.length > 0 || stats.currentSession !== null;

  return (
    <ScrollPanel
      className="h-full"
      toolbar={
        <Toolbar>
          <ToolbarContent>
            <PanelTabs />
          </ToolbarContent>
          <ToolbarActions>
            <Button
              variant="transparent"
              size="small"
              onClick={() => clearMutation.mutate()}
              disabled={!hasHistory || clearMutation.isPending}
              aria-label="Clear history"
            >
              <Trash2 className="size-4" />
            </Button>
          </ToolbarActions>
        </Toolbar>
      }
      footer={
        <div className="flex items-center justify-end px-3 py-2">
          <Button variant="muted" size="small" onClick={handleQuit}>
            Quit
          </Button>
        </div>
      }
    >
      {!hasHistory ? (
        <div className="relative min-h-60 px-3 pt-1 pb-3">
          <EmptyState
            placement="center"
            title="No activity yet"
            description="Once agents keep your Mac awake, you’ll see total awake time, a per-agent breakdown, and a timeline of recent sessions here."
            media={
              <div className="flex size-12 items-center justify-center rounded-full bg-control">
                <HistoryIcon className="size-5 text-secondary" />
              </div>
            }
          />
        </div>
      ) : (
        <div className="flex flex-col gap-4 px-3 pt-1 pb-3">
          <div className="grid grid-cols-3 gap-2">
            <StatTile label="All time" value={formatDuration(stats.totalAwakeMs)} />
            <StatTile label="Today" value={formatDuration(stats.todayAwakeMs)} />
            <StatTile label="Sessions" value={String(stats.sessionCount)} />
          </div>

          {stats.currentSession ? (
            <div className="flex items-center gap-3 rounded-xl bg-control-subtle px-3 py-2.5">
              <div className="flex size-8 shrink-0 items-center justify-center rounded-full bg-control">
                <Coffee className="size-4 text-green" />
              </div>
              <div className="min-w-0 flex-1">
                <Text variant="strong">In progress</Text>
                <Text variant="small" color="secondary" className="mt-0.5 block">
                  {sessionAgentNames(stats.currentSession)}
                </Text>
              </div>
              <Text variant="small-strong" className="tabular-nums">
                {formatDuration(stats.currentSession.durationMs)}
              </Text>
            </div>
          ) : null}

          {stats.perAgent.length > 0 ? (
            <div className="flex flex-col gap-2">
              <SectionLabel>By agent</SectionLabel>
              <div className="overflow-hidden rounded-xl bg-control-subtle">
                <List.Root>
                  {stats.perAgent.map((agent) => (
                    <List.Item key={agent.id}>
                      <List.ItemIcon>
                        <Bot className="size-4 text-secondary" />
                      </List.ItemIcon>
                      <List.ItemContent>
                        <List.ItemTitle>{agent.name}</List.ItemTitle>
                      </List.ItemContent>
                      <List.ItemAccessory>
                        <Text variant="small-strong" color="secondary" className="tabular-nums">
                          {formatDuration(agent.durationMs)}
                        </Text>
                      </List.ItemAccessory>
                    </List.Item>
                  ))}
                </List.Root>
              </div>
            </div>
          ) : null}

          {stats.recentSessions.length > 0 ? (
            <div className="flex flex-col gap-2">
              <SectionLabel>Recent sessions</SectionLabel>
              <div className="overflow-hidden rounded-xl bg-control-subtle">
                <List.Root>
                  {stats.recentSessions.map((session: AwakeSession) => (
                    <List.Item key={session.id}>
                      <List.ItemContent>
                        <List.ItemTitle>{formatSessionTime(session.startedAt)}</List.ItemTitle>
                        <List.ItemDescription>{sessionAgentNames(session)}</List.ItemDescription>
                      </List.ItemContent>
                      <List.ItemAccessory>
                        <Text variant="small-strong" color="secondary" className="tabular-nums">
                          {formatDuration(session.durationMs)}
                        </Text>
                      </List.ItemAccessory>
                    </List.Item>
                  ))}
                </List.Root>
              </div>
            </div>
          ) : null}
        </div>
      )}
    </ScrollPanel>
  );
}
