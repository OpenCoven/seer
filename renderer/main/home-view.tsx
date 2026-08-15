import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Bot, Coffee, Moon } from "lucide-react";

import { useRendererBridge } from "../bridge/renderer-bridge-context";
import type { ActiveAgent, AppSnapshot, KeepAwakeMode } from "../bridge/types";
import { PanelTabs } from "../components/panel-tabs";
import { SnapshotAvailability } from "../components/snapshot-availability";
import {
  Badge,
  Button,
  EmptyState,
  List,
  ScrollPanel,
  SegmentedControl,
  SegmentedControlItem,
  Text,
  Toolbar,
  ToolbarActions,
  ToolbarContent,
} from "../ui/primitives";
import { useAppSnapshot, writeAppSnapshot } from "./root-view";

function sourceLabel(source: ActiveAgent["source"]): string {
  if (source === "both") return "Process + session";
  if (source === "process") return "Process";
  return "Session";
}

export { sourceLabel };

export function UpdateNotice({
  availableVersion,
  checking,
  onView,
  onCheck,
  interactionsDisabled = false,
}: {
  availableVersion: string;
  checking: boolean;
  onView: () => void;
  onCheck: () => void;
  interactionsDisabled?: boolean;
}) {
  return (
    <div className="flex items-center gap-2 rounded-xl bg-control-subtle px-3 py-2">
      <Text variant="small-strong" className="min-w-0 flex-1">
        Seer {availableVersion} is available
      </Text>
      <Button variant="muted" size="small" disabled={interactionsDisabled} onClick={onView}>
        View release
      </Button>
      <Button
        variant="muted"
        size="small"
        disabled={interactionsDisabled || checking}
        onClick={onCheck}
      >
        {checking ? "Checking…" : "Check again"}
      </Button>
    </div>
  );
}

export function snapshotBadgeLabel(
  snapshot: AppSnapshot | undefined,
  isPending: boolean,
  isError = false,
): string {
  if (!snapshot || isError) return isPending ? "Loading" : "Unavailable";
  return snapshot.monitor.keepingAwake ? "Awake" : "Sleep OK";
}

export function HomeSnapshotContent({
  snapshot,
  isPending,
  isError,
  modeMutationPending,
  updateMutationPending,
  onModeChange,
  onViewRelease,
  onCheckForUpdates,
}: {
  snapshot: AppSnapshot | undefined;
  isPending: boolean;
  isError: boolean;
  modeMutationPending: boolean;
  updateMutationPending: boolean;
  onModeChange: (mode: KeepAwakeMode) => void;
  onViewRelease: () => void;
  onCheckForUpdates: () => void;
}) {
  if (!snapshot) {
    return (
      <SnapshotAvailability
        isPending={isPending}
        loadingTitle="Loading Seer status"
        errorTitle="Status unavailable"
        errorDescription="Seer could not load its current status. Live updates will restore this view automatically."
        media={
          <div className="flex size-12 items-center justify-center rounded-full bg-control">
            <Bot className="size-5 text-secondary" />
          </div>
        }
      />
    );
  }

  const state = snapshot.monitor;
  const update = snapshot.update;
  const interactionsDisabled = isError;
  const agents = state.agents;
  const statusTitle = state.active ? "Keeping Mac awake" : "Idle";
  const statusDescription = state.active
    ? `${agents.length} agent${agents.length === 1 ? "" : "s"} working`
    : "Sleep allowed when no agents are working";

  return (
    <div className="flex flex-col gap-4 px-3 pt-1 pb-3">
        {isError ? (
          <div role="alert" className="rounded-xl bg-control-subtle px-3 py-2">
            <Text variant="small-strong">Status unavailable</Text>
            <Text variant="mini" color="secondary" className="mt-0.5 block">
              Showing last known status. Controls will return when live updates recover.
            </Text>
          </div>
        ) : null}

        {update?.availableVersion ? (
          <UpdateNotice
            availableVersion={update.availableVersion}
            checking={update.checking || updateMutationPending}
            interactionsDisabled={interactionsDisabled}
            onView={onViewRelease}
            onCheck={onCheckForUpdates}
          />
        ) : null}

        <div className="flex items-start gap-3 rounded-xl bg-control-subtle px-3 py-3">
          <div className="mt-0.5 flex size-8 shrink-0 items-center justify-center rounded-full bg-control">
            {state.active ? (
              <Coffee className="size-4 text-green" />
            ) : (
              <Moon className="size-4 text-secondary" />
            )}
          </div>
          <div className="min-w-0 flex-1">
            <Text variant="strong">{statusTitle}</Text>
            <Text variant="small" color="secondary" className="mt-0.5 block">
              {statusDescription}
            </Text>
          </div>
        </div>

        <div className="flex flex-col gap-2 rounded-xl bg-control-subtle px-3 py-3">
          <Text variant="small-strong" color="secondary">
            Keep awake prevents
          </Text>
          <SegmentedControl aria-label="Keep awake mode" className="w-full">
            <SegmentedControlItem
              selected={state.keepAwakeMode === "system"}
              disabled={interactionsDisabled || modeMutationPending}
              onSelect={() => onModeChange("system")}
            >
              System
            </SegmentedControlItem>
            <SegmentedControlItem
              selected={state.keepAwakeMode === "display"}
              disabled={interactionsDisabled || modeMutationPending}
              onSelect={() => onModeChange("display")}
            >
              System + Display
            </SegmentedControlItem>
          </SegmentedControl>
          <Text variant="mini" color="tertiary">
            Display mode also keeps the screen on.
          </Text>
        </div>

        <div className="flex flex-col gap-2">
          <Text variant="small-strong" color="secondary">
            Active agents
          </Text>

          {agents.length === 0 ? (
            <div className="relative min-h-40 rounded-xl bg-control-subtle">
              <EmptyState
                placement="center"
                title="No agents working"
                description="When Claude Code, Codex, or other known agents are active, they’ll show up here and your Mac stays awake."
                media={
                  <div className="flex size-12 items-center justify-center rounded-full bg-control">
                    <Bot className="size-5 text-secondary" />
                  </div>
                }
              />
            </div>
          ) : (
            <div className="overflow-hidden rounded-xl bg-control-subtle">
              <List.Root>
                {agents.map((agent) => (
                  <List.Item key={agent.id}>
                    <List.ItemIcon>
                      <Bot className="size-4 text-secondary" />
                    </List.ItemIcon>
                    <List.ItemContent>
                      <List.ItemTitle>{agent.name}</List.ItemTitle>
                      <List.ItemDescription>{agent.detail}</List.ItemDescription>
                    </List.ItemContent>
                    <List.ItemAccessory>
                      <Text variant="mini" color="tertiary">
                        {sourceLabel(agent.source)}
                      </Text>
                    </List.ItemAccessory>
                  </List.Item>
                ))}
              </List.Root>
            </div>
          )}
        </div>
    </div>
  );
}

export function HomeView() {
  const bridge = useRendererBridge();
  const queryClient = useQueryClient();
  const { data: snapshot, isPending, isError } = useAppSnapshot();

  const modeMutation = useMutation({
    mutationFn: (mode: KeepAwakeMode) => bridge.setKeepAwakeMode(mode),
    onSuccess: (next) => writeAppSnapshot(queryClient, next),
  });
  const updateMutation = useMutation({
    mutationFn: () => bridge.requestUpdateCheck(),
    onSuccess: (next) => writeAppSnapshot(queryClient, next),
  });

  return (
    <ScrollPanel
      className="h-full"
      toolbar={
        <Toolbar>
          <ToolbarContent>
            <PanelTabs />
          </ToolbarContent>
          <ToolbarActions>
            <Badge color={snapshot && !isError && snapshot.monitor.keepingAwake ? "green" : "secondary"}>
              {snapshotBadgeLabel(snapshot, isPending, isError)}
            </Badge>
          </ToolbarActions>
        </Toolbar>
      }
      footer={
        <div className="flex items-center justify-end px-3 py-2">
          <Button variant="muted" size="small" onClick={() => void bridge.quit()}>
            Quit
          </Button>
        </div>
      }
    >
      <HomeSnapshotContent
        snapshot={snapshot}
        isPending={isPending}
        isError={isError}
        modeMutationPending={modeMutation.isPending}
        updateMutationPending={updateMutation.isPending}
        onModeChange={(mode) => modeMutation.mutate(mode)}
        onViewRelease={() => void bridge.openCurrentRelease()}
        onCheckForUpdates={() => updateMutation.mutate()}
      />
    </ScrollPanel>
  );
}
