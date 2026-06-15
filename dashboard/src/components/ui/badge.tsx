import { mergeProps } from "@base-ui/react/merge-props"
import { useRender } from "@base-ui/react/use-render"
import { cva, type VariantProps } from "class-variance-authority"

import { cn } from "@/lib/utils"

const badgeVariants = cva(
  "group/badge inline-flex w-fit shrink-0 items-center justify-center gap-1.5 whitespace-nowrap rounded-[var(--radius-sm)] border-2 border-foreground px-2.5 py-1 font-display text-[11px] font-extrabold uppercase tracking-[0.03em] text-foreground transition-[transform,box-shadow] focus-visible:ring-2 focus-visible:ring-ring [&>svg]:pointer-events-none [&>svg]:size-3!",
  {
    variants: {
      variant: {
        default: "bg-card",
        primary: "bg-primary",
        accent: "bg-accent",
        alert: "bg-destructive",
        blue: "bg-[var(--neutral)]",
        solid: "bg-foreground text-background",
        // legacy aliases kept so existing callers don't break
        secondary: "bg-card",
        destructive: "bg-destructive",
        outline: "bg-card",
        ghost: "border-transparent bg-transparent",
        link: "border-transparent bg-transparent underline-offset-4 hover:underline",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  }
)

function Badge({
  className,
  variant = "default",
  render,
  ...props
}: useRender.ComponentProps<"span"> & VariantProps<typeof badgeVariants>) {
  return useRender({
    defaultTagName: "span",
    props: mergeProps<"span">(
      {
        className: cn(badgeVariants({ variant }), className),
      },
      props
    ),
    render,
    state: {
      slot: "badge",
      variant,
    },
  })
}

export { Badge, badgeVariants }
