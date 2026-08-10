import * as React from "react";

/**
 * Seer-owned primitives for the panel UI.
 *
 * These are deliberately small, semantic components implemented against
 * Seer's own current needs — not a port of any Glaze component source. They
 * exist so shared renderer code (used by both the Glaze panel and the
 * standalone macOS window) never imports Glaze's own UI component library.
 */

function cx(...classes: Array<string | false | null | undefined>): string {
  return classes.filter(Boolean).join(" ");
}

// ---------------------------------------------------------------------------
// Button
// ---------------------------------------------------------------------------

export type ButtonVariant = "muted" | "transparent";
export type ButtonSize = "small";

export interface ButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant;
  size?: ButtonSize;
}

const buttonVariantClasses: Record<ButtonVariant, string> = {
  muted: "bg-control-subtle hover:bg-control text-secondary",
  transparent: "bg-transparent hover:bg-control-subtle text-secondary",
};

const buttonSizeClasses: Record<ButtonSize, string> = {
  small: "h-7 px-2.5 text-sm",
};

export function Button({
  variant = "muted",
  size = "small",
  className,
  type = "button",
  ...props
}: ButtonProps) {
  return (
    <button
      type={type}
      className={cx(
        "inline-flex items-center justify-center gap-1.5 rounded-lg font-medium transition-colors disabled:pointer-events-none disabled:opacity-50",
        buttonVariantClasses[variant],
        buttonSizeClasses[size],
        className,
      )}
      {...props}
    />
  );
}

// ---------------------------------------------------------------------------
// Badge
// ---------------------------------------------------------------------------

export type BadgeColor = "green" | "secondary";

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  color?: BadgeColor;
}

const badgeColorClasses: Record<BadgeColor, string> = {
  green: "bg-green/15 text-green",
  secondary: "bg-control-subtle text-secondary",
};

export function Badge({ color = "secondary", className, ...props }: BadgeProps) {
  return (
    <span
      className={cx(
        "inline-flex items-center rounded-full px-2 py-0.5 text-xs font-medium",
        badgeColorClasses[color],
        className,
      )}
      {...props}
    />
  );
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------

export type TextVariant = "strong" | "small" | "small-strong" | "large-strong" | "mini";
export type TextColor = "secondary" | "tertiary";

export interface TextProps extends React.HTMLAttributes<HTMLSpanElement> {
  variant?: TextVariant;
  color?: TextColor;
  truncate?: boolean;
}

const textVariantClasses: Record<TextVariant, string> = {
  strong: "text-sm font-semibold",
  small: "text-sm",
  "small-strong": "text-sm font-semibold",
  "large-strong": "text-base font-semibold",
  mini: "text-xs",
};

const textColorClasses: Record<TextColor, string> = {
  secondary: "text-secondary",
  tertiary: "text-tertiary",
};

export function Text({ variant = "small", color, truncate, className, ...props }: TextProps) {
  return (
    <span
      className={cx(
        textVariantClasses[variant],
        color ? textColorClasses[color] : undefined,
        truncate && "truncate",
        className,
      )}
      {...props}
    />
  );
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

export function Toolbar({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      data-toolbar=""
      className={cx(
        "drag-region flex h-13 shrink-0 items-center justify-between gap-2 px-3",
        className,
      )}
      {...props}
    />
  );
}

export function ToolbarContent({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cx("flex min-w-0 items-center gap-2", className)} {...props} />;
}

export function ToolbarActions({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cx("flex shrink-0 items-center gap-2", className)} {...props} />;
}

// ---------------------------------------------------------------------------
// ScrollPanel — toolbar/content/footer surface (replaces Glaze's ScrollArea)
// ---------------------------------------------------------------------------

export interface ScrollPanelProps {
  className?: string;
  toolbar?: React.ReactNode;
  footer?: React.ReactNode;
  children?: React.ReactNode;
}

export function ScrollPanel({ className, toolbar, footer, children }: ScrollPanelProps) {
  return (
    <div className={cx("flex flex-col", className)}>
      {toolbar}
      <div className="flex-1 overflow-y-auto">{children}</div>
      {footer}
    </div>
  );
}

// ---------------------------------------------------------------------------
// EmptyState
// ---------------------------------------------------------------------------

export interface EmptyStateProps {
  placement?: "center";
  title: React.ReactNode;
  description?: React.ReactNode;
  media?: React.ReactNode;
  className?: string;
}

export function EmptyState({ title, description, media, className }: EmptyStateProps) {
  return (
    <div
      role="status"
      className={cx(
        "flex h-full flex-col items-center justify-center gap-3 px-6 py-8 text-center",
        className,
      )}
    >
      {media}
      <div className="flex flex-col gap-1">
        <Text variant="strong">{title}</Text>
        {description ? (
          <Text variant="small" color="secondary">
            {description}
          </Text>
        ) : null}
      </div>
    </div>
  );
}

// ---------------------------------------------------------------------------
// List — row/container primitives
// ---------------------------------------------------------------------------

function ListRoot({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div role="list" className={cx("divide-y divide-control-subtle", className)} {...props} />
  );
}

function ListItem({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      role="listitem"
      className={cx("flex items-center gap-3 px-3 py-2.5", className)}
      {...props}
    />
  );
}

function ListItemIcon({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      className={cx(
        "flex size-8 shrink-0 items-center justify-center rounded-full bg-control",
        className,
      )}
      {...props}
    />
  );
}

function ListItemContent({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cx("min-w-0 flex-1", className)} {...props} />;
}

function ListItemTitle({ children }: { children: React.ReactNode }) {
  return (
    <Text variant="strong" truncate>
      {children}
    </Text>
  );
}

function ListItemDescription({ children }: { children: React.ReactNode }) {
  return (
    <Text variant="small" color="secondary" truncate className="block">
      {children}
    </Text>
  );
}

function ListItemAccessory({ className, ...props }: React.HTMLAttributes<HTMLDivElement>) {
  return <div className={cx("shrink-0", className)} {...props} />;
}

export const List = {
  Root: ListRoot,
  Item: ListItem,
  ItemIcon: ListItemIcon,
  ItemContent: ListItemContent,
  ItemTitle: ListItemTitle,
  ItemDescription: ListItemDescription,
  ItemAccessory: ListItemAccessory,
};

// ---------------------------------------------------------------------------
// SegmentedControl
// ---------------------------------------------------------------------------

export interface SegmentedControlProps extends React.HTMLAttributes<HTMLDivElement> {
  "aria-label": string;
}

export function SegmentedControl({ className, ...props }: SegmentedControlProps) {
  return (
    <div
      role="radiogroup"
      className={cx(
        "inline-flex items-center gap-0.5 rounded-lg bg-control-subtle p-0.5",
        className,
      )}
      {...props}
    />
  );
}

export interface SegmentedControlItemProps
  extends Omit<React.ButtonHTMLAttributes<HTMLButtonElement>, "onSelect"> {
  selected: boolean;
  onSelect: () => void;
}

export function SegmentedControlItem({
  selected,
  onSelect,
  className,
  type = "button",
  ...props
}: SegmentedControlItemProps) {
  return (
    <button
      type={type}
      role="radio"
      aria-checked={selected}
      data-selected={selected || undefined}
      onClick={onSelect}
      className={cx(
        "flex-1 rounded-md px-2.5 py-1 text-sm font-medium transition-colors",
        selected ? "bg-green text-white" : "text-secondary hover:bg-control",
        className,
      )}
      {...props}
    />
  );
}
