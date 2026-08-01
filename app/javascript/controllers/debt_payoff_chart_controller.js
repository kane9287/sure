import { Controller } from "@hotwired/stimulus";
import * as d3 from "d3";
import {
  createChartTooltip,
  CHART_TOOLTIP_CONTEXT_CLASSES,
  CHART_TOOLTIP_VALUE_CLASSES,
} from "utils/chart_tooltip";

// Balance-over-time chart for a debt payoff plan: one descending area/line
// from today's total balance to the debt-free date.
//
// Data arrives via `data-debt-payoff-chart-data-value` from
// DebtPlan#payoff_payload. Every currency string in the payload is already
// formatted server-side — this controller does no money math beyond the
// abbreviated y-axis ticks.
export default class extends Controller {
  static values = {
    data: Object,
    ariaLabel: String,
  };

  connect() {
    this._resize = this._draw.bind(this);
    window.addEventListener("resize", this._resize);

    if (typeof ResizeObserver !== "undefined") {
      this._observer = new ResizeObserver(() => this._draw());
      this._observer.observe(this.element);
    } else {
      this._draw();
    }

    // SVG attributes bake light/dark hex values at draw time, so repaint when
    // the theme flips.
    if (typeof MutationObserver !== "undefined") {
      this._themeObserver = new MutationObserver((mutations) => {
        if (mutations.some((m) => m.attributeName === "data-theme")) this._draw();
      });
      this._themeObserver.observe(document.documentElement, {
        attributes: true,
        attributeFilter: ["data-theme"],
      });
    }

    // A Turbo morph can wipe the SVG without changing the container size, so
    // ResizeObserver never fires. Redraw when we notice an empty container.
    this._onTurboRender = () => {
      if (!this.element.querySelector("svg")) this._draw();
    };
    document.addEventListener("turbo:render", this._onTurboRender);
    document.addEventListener("turbo:frame-load", this._onTurboRender);
  }

  disconnect() {
    window.removeEventListener("resize", this._resize);
    this._observer?.disconnect();
    this._themeObserver?.disconnect();
    if (this._onTurboRender) {
      document.removeEventListener("turbo:render", this._onTurboRender);
      document.removeEventListener("turbo:frame-load", this._onTurboRender);
    }
  }

  _draw() {
    const root = this.element;
    root.innerHTML = "";

    const data = this.dataValue || {};
    const points = (data.series || []).map((p) => ({
      date: this._parseLocalDate(p.date),
      balance: p.balance,
      balanceLabel: p.balance_formatted,
      interestLabel: p.interest_formatted,
      label: p.label,
    }));
    if (points.length < 2) return;

    const width = root.clientWidth || 720;
    const height = root.clientHeight || 240;
    if (width <= 0 || height <= 0) return;

    const isDark = document.documentElement.getAttribute("data-theme") === "dark";
    const textPrimary = isDark ? "#ffffff" : "#171717";
    const textSecondary = isDark ? "#cfcfcf" : "#737373";
    const borderSubdued = isDark ? "rgba(255,255,255,0.15)" : "rgba(0,0,0,0.10)";
    const containerBg = isDark ? "#0a0a0a" : "#ffffff";

    const yAxisVisible = width - 16 - 24 >= 320;
    const margin = { top: 20, right: 24, bottom: 28, left: yAxisVisible ? 44 : 16 };
    const innerWidth = width - margin.left - margin.right;
    const innerHeight = height - margin.top - margin.bottom;

    const x = d3
      .scaleTime()
      .domain([points[0].date, points[points.length - 1].date])
      .range([margin.left, margin.left + innerWidth]);
    const y = d3
      .scaleLinear()
      .domain([0, Math.max(d3.max(points, (p) => p.balance) || 1, 1)])
      .range([margin.top + innerHeight, margin.top]);

    const svg = d3
      .select(root)
      .append("svg")
      .attr("width", width)
      .attr("height", height)
      .attr("viewBox", `0 0 ${width} ${height}`)
      .attr("role", "img")
      .attr("aria-label", this.ariaLabelValue || "Debt payoff projection");

    const gradientId = `debt-payoff-fill-${this._id()}`;
    const gradient = svg
      .append("defs")
      .append("linearGradient")
      .attr("id", gradientId)
      .attr("x1", 0).attr("y1", 0).attr("x2", 0).attr("y2", 1);
    gradient.append("stop").attr("offset", "0%").attr("stop-color", textPrimary).attr("stop-opacity", 0.22);
    gradient.append("stop").attr("offset", "100%").attr("stop-color", textPrimary).attr("stop-opacity", 0);

    if (yAxisVisible) {
      y.ticks(3).forEach((tickValue) => {
        svg
          .append("line")
          .attr("x1", margin.left)
          .attr("x2", margin.left + innerWidth)
          .attr("y1", y(tickValue))
          .attr("y2", y(tickValue))
          .attr("stroke", borderSubdued)
          .attr("stroke-width", 1);
        svg
          .append("text")
          .attr("x", margin.left - 6)
          .attr("y", y(tickValue) + 3)
          .attr("text-anchor", "end")
          .attr("font-size", 12)
          .attr("fill", textSecondary)
          .text(this._fmtShort(tickValue));
      });
    }

    const area = d3
      .area()
      .x((d) => x(d.date))
      .y0(margin.top + innerHeight)
      .y1((d) => y(d.balance))
      .curve(d3.curveMonotoneX);

    const line = d3
      .line()
      .x((d) => x(d.date))
      .y((d) => y(d.balance))
      .curve(d3.curveMonotoneX);

    svg.append("path").datum(points).attr("fill", `url(#${gradientId})`).attr("d", area);

    svg
      .append("path")
      .datum(points)
      .attr("fill", "none")
      .attr("stroke", "var(--color-green-600)")
      .attr("stroke-width", 2)
      .attr("stroke-linejoin", "round")
      .attr("stroke-linecap", "round")
      .attr("d", line);

    // Debt-free marker at the terminal point.
    const last = points[points.length - 1];
    if (last.balance <= 0) {
      svg
        .append("circle")
        .attr("cx", x(last.date))
        .attr("cy", y(last.balance))
        .attr("r", 4)
        .attr("fill", "var(--color-green-600)")
        .attr("stroke", containerBg)
        .attr("stroke-width", 2);
    }

    const tickFmt = d3.timeFormat("%b %Y");
    const tickCount = Math.min(5, Math.max(2, Math.round(innerWidth / 80)));
    const tickGroup = svg.append("g");
    tickGroup
      .selectAll("text")
      .data(x.ticks(tickCount))
      .enter()
      .append("text")
      .attr("x", (d) => x(d))
      .attr("y", height - 8)
      .attr("text-anchor", "middle")
      .attr("font-size", 12)
      .attr("fill", textSecondary)
      .text((d) => tickFmt(d));

    const tickNodes = tickGroup.selectAll("text").nodes();
    for (let i = tickNodes.length - 1; i > 0; i--) {
      if (tickNodes[i].textContent === tickNodes[i - 1].textContent) tickNodes[i].remove();
    }

    const crosshair = svg
      .append("line")
      .attr("y1", margin.top)
      .attr("y2", margin.top + innerHeight)
      .attr("stroke", textSecondary)
      .attr("stroke-width", 1)
      .attr("stroke-dasharray", "2 2")
      .attr("pointer-events", "none")
      .style("display", "none");

    const hoverDot = svg
      .append("circle")
      .attr("r", 4)
      .attr("fill", "var(--color-green-600)")
      .attr("stroke", containerBg)
      .attr("stroke-width", 2)
      .attr("pointer-events", "none")
      .style("display", "none");

    if (getComputedStyle(root).position === "static") root.style.position = "relative";

    const tooltip = createChartTooltip(root);
    tooltip.style.transition = "left 80ms ease-out, top 80ms ease-out";
    const tooltipDate = document.createElement("div");
    tooltipDate.className = CHART_TOOLTIP_CONTEXT_CLASSES;
    const tooltipValue = document.createElement("div");
    tooltipValue.className = CHART_TOOLTIP_VALUE_CLASSES;
    const tooltipInterest = document.createElement("div");
    tooltipInterest.className = "text-xs text-subdued mt-0.5";
    tooltip.replaceChildren(tooltipDate, tooltipValue, tooltipInterest);

    const overlay = svg
      .append("rect")
      .attr("x", margin.left)
      .attr("y", margin.top)
      .attr("width", innerWidth)
      .attr("height", innerHeight)
      .attr("fill", "transparent")
      .style("cursor", "crosshair");

    const bisectDate = d3.bisector((d) => d.date).left;
    const labels = data.labels || {};

    overlay.on("pointermove", (event) => {
      const [mx, my] = d3.pointer(event);
      const xVal = x.invert(mx);
      const i = bisectDate(points, xVal);
      const a = points[Math.max(0, i - 1)];
      const b = points[Math.min(points.length - 1, i)];
      const point = !a ? b : !b ? a : xVal - a.date < b.date - xVal ? a : b;

      const hoverX = x(point.date);
      crosshair.attr("x1", hoverX).attr("x2", hoverX).style("display", null);
      hoverDot.attr("cx", hoverX).attr("cy", y(point.balance)).style("display", null);

      tooltipDate.textContent = point.label;
      tooltipValue.textContent = `${labels.balance || "Balance"}: ${point.balanceLabel}`;
      tooltipInterest.textContent = `${labels.interest || "Interest paid"}: ${point.interestLabel}`;

      tooltip.style.display = "block";
      const tipRect = tooltip.getBoundingClientRect();
      tooltip.style.left = `${Math.min(width - tipRect.width - 4, Math.max(4, mx + 12))}px`;
      tooltip.style.top = `${Math.max(4, my - tipRect.height - 8)}px`;
    });

    overlay.on("pointerleave", () => {
      crosshair.style("display", "none");
      hoverDot.style("display", "none");
      tooltip.style.display = "none";
    });
  }

  // Date-only payload strings parse as UTC midnight in `new Date(str)`, which
  // shifts the displayed day back one west of Greenwich.
  _parseLocalDate(s) {
    const [y, m, d] = String(s).split("-").map(Number);
    return new Date(y, m - 1, d);
  }

  _fmtShort(amount) {
    const symbol = this.dataValue?.currency_symbol || "$";
    const abs = Math.abs(amount);
    if (abs >= 1_000_000) return `${symbol}${(amount / 1_000_000).toFixed(1).replace(/\.0$/, "")}M`;
    if (abs >= 1_000) return `${symbol}${(amount / 1_000).toFixed(1).replace(/\.0$/, "")}K`;
    return `${symbol}${Math.round(amount).toLocaleString()}`;
  }

  _id() {
    if (!this._cachedId) this._cachedId = Math.random().toString(36).slice(2, 8);
    return this._cachedId;
  }
}
