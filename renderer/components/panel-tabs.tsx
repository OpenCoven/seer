import { SegmentedControl, SegmentedControlItem } from "@glaze/core/components";
import { useNavigate, useRouterState } from "@tanstack/react-router";

/** Shared Status / History switcher. Selection is driven by the current route. */
export function PanelTabs() {
  const navigate = useNavigate();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const value = pathname.startsWith("/history") ? "history" : "status";

  const handleChange = (next: string) => {
    void navigate({ to: next === "history" ? "/history" : "/" });
  };

  return (
    <SegmentedControl
      value={value}
      onValueChange={handleChange}
      aria-label="Panel view"
      size="small"
    >
      <SegmentedControlItem value="status">Status</SegmentedControlItem>
      <SegmentedControlItem value="history">History</SegmentedControlItem>
    </SegmentedControl>
  );
}
