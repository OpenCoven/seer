import { useNavigate, useRouterState } from "@tanstack/react-router";

import { SegmentedControl, SegmentedControlItem } from "../ui/primitives";

export type PanelRouteValue = "status" | "history";

/** Pure: maps the current route pathname to which panel tab is selected. */
export function pathnameToPanelValue(pathname: string): PanelRouteValue {
  return pathname.startsWith("/history") ? "history" : "status";
}

/** Pure: maps a panel tab selection back to the route it navigates to. */
export function panelValueToPath(value: PanelRouteValue): string {
  return value === "history" ? "/history" : "/";
}

/** Shared Status / History switcher. Selection is driven by the current route. */
export function PanelTabs() {
  const navigate = useNavigate();
  const pathname = useRouterState({ select: (state) => state.location.pathname });
  const value = pathnameToPanelValue(pathname);

  const handleChange = (next: PanelRouteValue) => {
    void navigate({ to: panelValueToPath(next) });
  };

  return (
    <SegmentedControl aria-label="Panel view">
      <SegmentedControlItem selected={value === "status"} onSelect={() => handleChange("status")}>
        Status
      </SegmentedControlItem>
      <SegmentedControlItem
        selected={value === "history"}
        onSelect={() => handleChange("history")}
      >
        History
      </SegmentedControlItem>
    </SegmentedControl>
  );
}
