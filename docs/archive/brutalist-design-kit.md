# Neo-Brutalist Design Kit (portable)

Self-contained copy of the "Railway Superpowers OS" theme from the Cadence HR app.
Drop into any **Next.js (App Router) + Tailwind CSS v4 + shadcn/base-ui** project.

Cream canvas · hard 2px ink borders · hard offset shadows (no blur) · pastel fills ·
hover-translate · Montserrat / Space Grotesk / JetBrains Mono. Light-only, no dark mode.

---

## 1. Dependencies

```bash
pnpm add class-variance-authority clsx tailwind-merge @base-ui/react
# Tailwind v4 + next already assumed present
```

> Components use `@base-ui/react` (NOT radix). If your shadcn install uses radix,
> swap the `*Primitive` imports for radix equivalents — the className strings (the
> actual design) stay identical.

---

## 2. `src/lib/utils.ts`

```ts
import { clsx, type ClassValue } from "clsx"
import { twMerge } from "tailwind-merge"

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
```

---

## 3. `src/app/globals.css` — THE THEME (single source of truth)

Recolor the whole app by editing only `:root`. Every component maps to these tokens.

```css
@import "tailwindcss";

@theme {
  --font-sans: var(--font-montserrat);
  --font-mono: var(--font-jetbrains-mono);
  --font-display: var(--font-space-grotesk);

  --color-background: var(--bg-0);
  --color-foreground: var(--tx-hi);

  /* shadcn/ui semantic tokens mapped to the neo-brutalist light palette */
  --color-card: var(--surface);
  --color-card-foreground: var(--tx-hi);
  --color-popover: var(--surface);
  --color-popover-foreground: var(--tx-hi);
  --color-primary: var(--primary-fill);
  --color-primary-foreground: var(--dark);
  --color-secondary: var(--surface);
  --color-secondary-foreground: var(--tx-hi);
  --color-muted: var(--bg-3);
  --color-muted-foreground: var(--tx-md);
  --color-accent: var(--accent-fill);
  --color-accent-foreground: var(--dark);
  --color-destructive: var(--alert-fill);
  --color-destructive-foreground: var(--dark);
  --color-border: var(--dark);
  --color-input: var(--dark);
  --color-ring: var(--dark);

  --radius-lg: var(--radius-lg);
  --radius-md: var(--radius);
  --radius-sm: var(--radius-sm);
}

:root {
  /* ===== Neo-brutalist palette ===== */
  --dark:    #020309;   /* ink — borders + primary text */
  --canvas:  #faf3e3;   /* page */
  --surface: #fdfaf1;   /* cards / panels */
  --neutral: #e5f5f9;   /* light blue fill */
  --primary-fill: #d2ecd0; /* mint */
  --accent-fill:  #fdeec4; /* cream yellow */
  --alert-fill:   #f3c1c0; /* pink */

  /* ----- Surfaces ----- */
  --bg-0: var(--canvas);    /* page */
  --bg-1: var(--surface);   /* rail / panel */
  --bg-2: var(--surface);   /* card */
  --bg-3: #f3ead2;          /* card hover / inset (canvas-tint) */
  --bg-4: var(--primary-fill); /* active / control → mint */

  /* ----- Hairlines / dividers (ink alphas) ----- */
  --line:   rgba(2, 3, 9, 0.10);
  --line-2: rgba(2, 3, 9, 0.18);
  --line-3: rgba(2, 3, 9, 0.30);

  /* ----- Text ----- */
  --tx-hi:  #020309;   /* primary */
  --tx-md:  #4a4a52;   /* secondary */
  --tx-lo:  #6a6a72;   /* tertiary */
  --tx-dim: #8a8a90;   /* faint */

  /* ----- Status: text tone + pastel fill pairs ----- */
  --blue:   #2563a8;   /* info text */
  --teal:   #1f7a52;   /* live/ok text (green) */
  --amber:  #9a6b12;   /* warn text (gold) */
  --rose:   #b23b48;   /* risk text (red) */
  --green:  #1f7a52;
  --orchid: #7a4dc0;   /* secondary accent text */

  --live-fill:  var(--primary-fill);
  --human-fill: var(--accent-fill);
  --risk-fill:  var(--alert-fill);
  --info-fill:  var(--neutral);
  --ok-fill:    var(--primary-fill);

  --live:  var(--teal);
  --human: var(--amber);
  --risk:  var(--rose);
  --info:  var(--blue);
  --ok:    var(--green);

  /* ----- Brutalist primitives ----- */
  --bd: 2px solid var(--dark);
  --shadow-sm:    4px 4px 0 var(--dark);
  --shadow-hover: 6px 6px 0 var(--dark);
  --shadow-lg:    12px 12px 0 var(--dark);

  --radius:    14px;
  --radius-sm: 10px;
  --radius-lg: 18px;
}

@layer base {
  * {
    @apply border-border outline-ring/50;
  }
  body {
    @apply bg-background text-foreground antialiased;
    font-feature-settings: "rlig" 1, "calt" 1;
    text-rendering: optimizeLegibility;
  }
}

/* ===== Page background — flat canvas + faint ink dot-grid ===== */
.app-bg {
  position: fixed; inset: 0; z-index: -1; pointer-events: none;
  background: var(--canvas);
}
.app-bg::after {
  content: ""; position: absolute; inset: 0;
  background-image: radial-gradient(rgba(2, 3, 9, 0.05) 1.4px, transparent 1.4px);
  background-size: 26px 26px;
  opacity: 0.7;
}

/* ===== Brand mark — flat mint square lettermark ===== */
.brand-mark {
  width: 38px; height: 38px; border-radius: var(--radius-sm);
  background: var(--primary-fill);
  border: var(--bd);
  box-shadow: var(--shadow-sm);
  display: grid; place-items: center;
  font-family: var(--font-display, "Space Grotesk", system-ui, sans-serif);
  font-weight: 800; font-size: 20px; color: var(--dark);
  overflow: hidden;
}

.dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; background: var(--dark); }
.dot.live { background: var(--green); box-shadow: 0 0 0 0 rgba(31, 122, 82, 0.6); animation: pulse 2s infinite; }
@keyframes pulse {
  0%   { box-shadow: 0 0 0 0 rgba(31, 122, 82, 0.5); }
  70%  { box-shadow: 0 0 0 6px rgba(31, 122, 82, 0); }
  100% { box-shadow: 0 0 0 0 rgba(31, 122, 82, 0); }
}

/* ===== Reusable brutalist utilities ===== */
.nb {
  border: var(--bd);
  border-radius: var(--radius);
  box-shadow: var(--shadow-sm);
  background: var(--surface);
}
.nb-hover {
  transition: transform 80ms ease, box-shadow 80ms ease, background 80ms ease;
}
.nb-hover:hover {
  transform: translate(-2px, -2px);
  box-shadow: var(--shadow-hover);
}
.nb-chip {
  display: inline-flex; align-items: center; gap: 6px;
  font-family: var(--font-display, "Space Grotesk", system-ui, sans-serif);
  font-size: 11px; font-weight: 800; letter-spacing: 0.02em;
  padding: 4px 10px; border: 2px solid var(--dark); border-radius: var(--radius-sm);
  background: var(--surface); color: var(--dark); white-space: nowrap;
}
.nb-chip.is-primary { background: var(--primary-fill); }
.nb-chip.is-accent  { background: var(--accent-fill); }
.nb-chip.is-alert   { background: var(--alert-fill); }
.nb-chip.is-blue    { background: var(--neutral); }
```

---

## 4. `src/app/layout.tsx` — fonts + background

```tsx
import type { Metadata } from 'next'
import { Space_Grotesk, Montserrat, JetBrains_Mono } from 'next/font/google'
import './globals.css'

const spaceGrotesk = Space_Grotesk({
  subsets: ['latin'],
  weight: ['500', '600', '700'],
  variable: '--font-space-grotesk',
})
const montserrat = Montserrat({
  subsets: ['latin'],
  weight: ['400', '500', '600', '700'],
  variable: '--font-montserrat',
})
const jetbrainsMono = JetBrains_Mono({
  subsets: ['latin'],
  weight: ['500', '600', '700'],
  variable: '--font-jetbrains-mono',
})

export const metadata: Metadata = {
  title: 'Your App',
  description: '...',
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className={`${montserrat.variable} ${jetbrainsMono.variable} ${spaceGrotesk.variable} font-sans`}>
        <div className="app-bg" />
        {children}
      </body>
    </html>
  )
}
```

---

## 5. Primitives — `src/components/ui/*.tsx`

### `button.tsx`

```tsx
import { Button as ButtonPrimitive } from "@base-ui/react/button"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const buttonVariants = cva(
  "group/button inline-flex shrink-0 items-center justify-center rounded-[var(--radius-sm)] border-2 border-foreground bg-clip-padding font-display text-sm font-bold tracking-[-0.01em] whitespace-nowrap shadow-[var(--shadow-sm)] transition-[transform,box-shadow,background,color] duration-100 outline-none select-none hover:-translate-x-px hover:-translate-y-px hover:shadow-[var(--shadow-hover)] active:translate-x-0 active:translate-y-0 active:shadow-[var(--shadow-sm)] focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2 focus-visible:ring-offset-background disabled:pointer-events-none disabled:opacity-50 disabled:shadow-none aria-invalid:border-destructive [&_svg]:pointer-events-none [&_svg]:shrink-0 [&_svg:not([class*='size-'])]:size-4",
  {
    variants: {
      variant: {
        default: "bg-primary text-primary-foreground hover:bg-foreground hover:text-background",
        outline: "bg-card text-foreground hover:bg-accent aria-expanded:bg-accent",
        secondary: "bg-card text-secondary-foreground hover:bg-accent aria-expanded:bg-accent",
        ghost: "border-transparent shadow-none hover:border-foreground hover:bg-accent hover:text-foreground hover:shadow-[var(--shadow-sm)] aria-expanded:bg-accent",
        destructive: "bg-destructive text-destructive-foreground hover:bg-foreground hover:text-background",
        link: "border-transparent shadow-none hover:translate-x-0 hover:translate-y-0 hover:shadow-none text-foreground underline-offset-4 hover:underline",
      },
      size: {
        default: "h-8 gap-1.5 px-2.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2",
        xs: "h-6 gap-1 rounded-[min(var(--radius-md),10px)] px-2 text-xs in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3",
        sm: "h-7 gap-1 rounded-[min(var(--radius-md),12px)] px-2.5 text-[0.8rem] in-data-[slot=button-group]:rounded-lg has-data-[icon=inline-end]:pr-1.5 has-data-[icon=inline-start]:pl-1.5 [&_svg:not([class*='size-'])]:size-3.5",
        lg: "h-9 gap-1.5 px-2.5 has-data-[icon=inline-end]:pr-2 has-data-[icon=inline-start]:pl-2",
        icon: "size-8",
        "icon-xs": "size-6 rounded-[min(var(--radius-md),10px)] in-data-[slot=button-group]:rounded-lg [&_svg:not([class*='size-'])]:size-3",
        "icon-sm": "size-7 rounded-[min(var(--radius-md),12px)] in-data-[slot=button-group]:rounded-lg",
        "icon-lg": "size-9",
      },
    },
    defaultVariants: { variant: "default", size: "default" },
  }
)

function Button({
  className,
  variant = "default",
  size = "default",
  ...props
}: ButtonPrimitive.Props & VariantProps<typeof buttonVariants>) {
  return (
    <ButtonPrimitive
      data-slot="button"
      className={cn(buttonVariants({ variant, size, className }))}
      {...props}
    />
  )
}

export { Button, buttonVariants }
```

### `card.tsx`

```tsx
import * as React from "react"

import { cn } from "@/lib/utils"

function Card({
  className,
  size = "default",
  ...props
}: React.ComponentProps<"div"> & { size?: "default" | "sm" }) {
  return (
    <div
      data-slot="card"
      data-size={size}
      className={cn(
        "group/card flex flex-col gap-4 overflow-hidden rounded-[var(--radius)] border-2 border-foreground bg-card py-4 text-sm text-card-foreground shadow-[var(--shadow-sm)] has-data-[slot=card-footer]:pb-0 has-[>img:first-child]:pt-0 data-[size=sm]:gap-3 data-[size=sm]:py-3 data-[size=sm]:has-data-[slot=card-footer]:pb-0 *:[img:first-child]:rounded-t-[var(--radius)] *:[img:last-child]:rounded-b-[var(--radius)]",
        className
      )}
      {...props}
    />
  )
}

function CardHeader({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-header"
      className={cn(
        "group/card-header @container/card-header grid auto-rows-min items-start gap-1 rounded-t-xl px-4 group-data-[size=sm]/card:px-3 has-data-[slot=card-action]:grid-cols-[1fr_auto] has-data-[slot=card-description]:grid-rows-[auto_auto] [.border-b]:pb-4 group-data-[size=sm]/card:[.border-b]:pb-3",
        className
      )}
      {...props}
    />
  )
}

function CardTitle({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-title"
      className={cn("font-display text-base leading-snug font-bold tracking-[-0.01em] group-data-[size=sm]/card:text-sm", className)}
      {...props}
    />
  )
}

function CardDescription({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="card-description" className={cn("text-sm text-muted-foreground", className)} {...props} />
  )
}

function CardAction({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="card-action" className={cn("col-start-2 row-span-2 row-start-1 self-start justify-self-end", className)} {...props} />
  )
}

function CardContent({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div data-slot="card-content" className={cn("px-4 group-data-[size=sm]/card:px-3", className)} {...props} />
  )
}

function CardFooter({ className, ...props }: React.ComponentProps<"div">) {
  return (
    <div
      data-slot="card-footer"
      className={cn("flex items-center rounded-b-[var(--radius)] border-t-2 border-foreground bg-muted p-4 group-data-[size=sm]/card:p-3", className)}
      {...props}
    />
  )
}

export { Card, CardHeader, CardFooter, CardTitle, CardAction, CardDescription, CardContent }
```

### `input.tsx`

```tsx
import * as React from "react"
import { Input as InputPrimitive } from "@base-ui/react/input"

import { cn } from "@/lib/utils"

function Input({ className, type, ...props }: React.ComponentProps<"input">) {
  return (
    <InputPrimitive
      type={type}
      data-slot="input"
      className={cn(
        "h-9 w-full min-w-0 rounded-[var(--radius-sm)] border-2 border-foreground bg-card px-3 py-1 text-base transition-[box-shadow,transform] outline-none file:inline-flex file:h-7 file:border-0 file:bg-transparent file:text-sm file:font-medium file:text-foreground placeholder:text-muted-foreground focus-visible:shadow-[var(--shadow-sm)] focus-visible:-translate-x-px focus-visible:-translate-y-px disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50 aria-invalid:border-destructive md:text-sm",
        className
      )}
      {...props}
    />
  )
}

export { Input }
```

### `table.tsx`

```tsx
"use client"

import * as React from "react"

import { cn } from "@/lib/utils"

function Table({ className, ...props }: React.ComponentProps<"table">) {
  return (
    <div
      data-slot="table-container"
      className="relative w-full overflow-x-auto rounded-[var(--radius)] border-2 border-foreground shadow-[var(--shadow-sm)] bg-card"
    >
      <table data-slot="table" className={cn("w-full caption-bottom text-sm", className)} {...props} />
    </div>
  )
}

function TableHeader({ className, ...props }: React.ComponentProps<"thead">) {
  return <thead data-slot="table-header" className={cn("bg-[var(--neutral)] [&_tr]:border-b-2 [&_tr]:border-foreground", className)} {...props} />
}

function TableBody({ className, ...props }: React.ComponentProps<"tbody">) {
  return <tbody data-slot="table-body" className={cn("[&_tr:last-child]:border-0", className)} {...props} />
}

function TableFooter({ className, ...props }: React.ComponentProps<"tfoot">) {
  return <tfoot data-slot="table-footer" className={cn("border-t-2 border-foreground bg-muted font-medium [&>tr]:last:border-b-0", className)} {...props} />
}

function TableRow({ className, ...props }: React.ComponentProps<"tr">) {
  return (
    <tr
      data-slot="table-row"
      className={cn("border-b border-[var(--line-2)] transition-colors hover:bg-muted has-aria-expanded:bg-muted data-[state=selected]:bg-muted", className)}
      {...props}
    />
  )
}

function TableHead({ className, ...props }: React.ComponentProps<"th">) {
  return (
    <th
      data-slot="table-head"
      className={cn("h-11 px-3 text-left align-middle font-display text-[11px] font-extrabold uppercase tracking-[0.08em] whitespace-nowrap text-foreground [&:has([role=checkbox])]:pr-0", className)}
      {...props}
    />
  )
}

function TableCell({ className, ...props }: React.ComponentProps<"td">) {
  return <td data-slot="table-cell" className={cn("px-3 py-2.5 align-middle whitespace-nowrap [&:has([role=checkbox])]:pr-0", className)} {...props} />
}

function TableCaption({ className, ...props }: React.ComponentProps<"caption">) {
  return <caption data-slot="table-caption" className={cn("mt-4 text-sm text-muted-foreground", className)} {...props} />
}

export { Table, TableHeader, TableBody, TableFooter, TableHead, TableRow, TableCell, TableCaption }
```

### `badge.tsx`

```tsx
import * as React from "react"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const badgeVariants = cva(
  "inline-flex items-center gap-1.5 whitespace-nowrap rounded-[var(--radius-sm)] border-2 border-foreground px-2.5 py-1 font-display text-[11px] font-extrabold uppercase tracking-[0.03em] text-foreground [&_svg]:pointer-events-none [&_svg]:size-3",
  {
    variants: {
      variant: {
        default: "bg-card",
        primary: "bg-primary",
        accent: "bg-accent",
        alert: "bg-destructive",
        blue: "bg-[var(--neutral)]",
        solid: "bg-foreground text-background",
      },
    },
    defaultVariants: { variant: "default" },
  }
)

function Badge({
  className,
  variant,
  ...props
}: React.ComponentProps<"span"> & VariantProps<typeof badgeVariants>) {
  return <span data-slot="badge" className={cn(badgeVariants({ variant }), className)} {...props} />
}

export { Badge, badgeVariants }
```

---

## 6. Design rules (when building new components)

| Rule | Value |
|------|-------|
| Border | always `border-2 border-foreground` (2px ink) |
| Shadow | hard offset, no blur: `shadow-[var(--shadow-sm)]` |
| Hover (interactive) | `translate(-2px,-2px)` + grow to `--shadow-hover` |
| Active | reset translate + back to `--shadow-sm` (press feel) |
| Radius | cards `--radius` (14px), controls/chips `--radius-sm` (10px) |
| Headings / labels / buttons | `font-display` (Space Grotesk), weight 700-800 |
| Body | `font-sans` (Montserrat) |
| Numbers / code / KPIs | `font-mono` (JetBrains Mono) |
| Section labels / table heads / badges | uppercase, tracked (`tracking-[0.08em]`), 11px, extrabold |
| Fills | mint=primary/ok, yellow=accent/warn, pink=alert/destructive, blue=info |
| NO | gradients, blur, glow, soft shadows, dark mode |

**Recolor entire app:** edit only the 7 palette vars at top of `:root` in `globals.css`.

**Quick brutalist box without a component:** `class="nb nb-hover"`. Quick chip: `class="nb-chip is-primary"`.
```
