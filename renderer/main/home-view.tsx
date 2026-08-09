import {
  Badge,
  Button,
  EmptyState,
  Field,
  FieldGroup,
  FieldSet,
  List,
  ScrollArea,
  SegmentedControl,
  SegmentedControlItem,
  Text,
  Toolbar,
  ToolbarActions,
  ToolbarContent,
} from "@glaze/core/components";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Bot, Coffee, Moon } from "lucide-react";

import { PanelTabs } from "../components/panel-tabs";
import {
  EMPTY_STATE,
  fetchAgentState,
  updateKeepAwakeMode,
  type ActiveAgent,
  type KeepAwakeMode,
} from "../lib/agents";

function sourceLabel(source: ActiveAgent["source"]): string {
  if (source === "both") return "Process + session";
  if (source === "process") return "Process";
  return "Session";
}

export function HomeView() {
  const queryClient = useQueryClient();
  const { data: state = EMPTY_STATE, isLoading } = useQuery({
    queryKey: ["agentState"],
    queryFn: fetchAgentState,
  });

  const modeMutation = useMutation({
    mutationFn: (mode: KeepAwakeMode) => updateKeepAwakeMode(mode),
    onSuccess: (next) => queryClient.setQueryData(["agentState"], next),
  });

  const handleModeChange = (value: string) => {
    if (value !== "system" && value !== "display") return;
    modeMutation.mutate(value);
  };

  const handleQuit = () => {
    void window.glazeAPI.glaze.ipc.invoke("app:quit");
  };

  const agents = state.agents;
  const statusTitle = state.active ? "Keeping Mac awake" : "Idle";
  const statusDescription = state.active
    ? `${agents.length} agent${agents.length === 1 ? "" : "s"} working`
    : "Sleep allowed when no agents are working";

  return (
    <ScrollArea
      className="h-full"
      toolbar={
        <Toolbar>
          <ToolbarContent>
            <PanelTabs />
          </ToolbarContent>
          <ToolbarActions>
            <Badge color={state.keepingAwake ? "green" : "secondary"}>
              {state.keepingAwake ? "Awake" : "Sleep OK"}
            </Badge>
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
      <div className="flex flex-col gap-4 px-3 pt-1 pb-3">
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
              {isLoading ? "Scanning…" : statusDescription}
            </Text>
          </div>
        </div>

        <FieldSet title="Keep awake prevents">
          <FieldGroup>
            <Field orientation="vertical" description="Display mode also keeps the screen on.">
              <SegmentedControl
                value={state.keepAwakeMode}
                onValueChange={handleModeChange}
                aria-label="Keep awake mode"
                size="small"
                className="w-full"
              >
                <SegmentedControlItem value="system">System</SegmentedControlItem>
                <SegmentedControlItem value="display">System + Display</SegmentedControlItem>
              </SegmentedControl>
            </Field>
          </FieldGroup>
        </FieldSet>

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
              <List.Root items={agents} getItemKey={(agent) => agent.id}>
                {agents.map((agent) => (
                  <List.Item key={agent.id} item={agent}>
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
    </ScrollArea>
  );
}
