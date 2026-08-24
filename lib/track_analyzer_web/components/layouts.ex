defmodule TrackAnalyzerWeb.Layouts do
  @moduledoc false

  use TrackAnalyzerWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :any, default: nil
  attr :active, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-screen">
      <header class="sticky top-0 z-[900] border-b border-[var(--line)] bg-[color-mix(in_srgb,var(--canvas)_82%,transparent)] backdrop-blur-xl">
        <div class="mx-auto flex h-16 max-w-[94rem] items-center gap-4 px-4 sm:px-6 lg:px-8">
          <.link
            navigate={~p"/"}
            id="brand-link"
            aria-label="Track / Atlas"
            class="group flex shrink-0 items-center gap-2.5"
          >
            <span class="grid size-9 place-items-center rounded-xl bg-[var(--ink)] text-[var(--accent)] shadow-sm transition group-hover:-rotate-3">
              <.icon name="hero-map" class="size-5" />
            </span>
            <span class="hidden text-sm font-black tracking-[-0.03em] sm:block">Track / Atlas</span>
          </.link>

          <nav
            id="primary-navigation"
            class="ml-auto flex items-center gap-1 overflow-x-auto"
            aria-label="Primary navigation"
          >
            <.nav_link
              to={~p"/"}
              icon="hero-squares-2x2"
              label="Overview"
              active={@active == "overview"}
            />
            <.nav_link
              to={~p"/tracks"}
              icon="hero-list-bullet"
              label="Tracks"
              active={@active == "tracks"}
            />
            <.nav_link
              to={~p"/speed"}
              icon="hero-bolt"
              label="Speed"
              active={@active == "speed"}
            />
            <.nav_link
              to={~p"/explore"}
              icon="hero-globe-alt"
              label="Explore"
              active={@active == "explore"}
            />
            <.nav_link
              to={~p"/compare"}
              icon="hero-arrows-right-left"
              label="Compare"
              active={@active == "compare"}
            />
          </nav>

          <.link
            navigate={~p"/import"}
            id="nav-import"
            class="hidden min-h-10 shrink-0 items-center gap-2 rounded-xl bg-[var(--accent)] px-3.5 text-sm font-bold text-[var(--accent-ink)] shadow-sm transition hover:-translate-y-0.5 sm:inline-flex"
          >
            <.icon name="hero-arrow-up-tray" class="size-4" /> Upload
          </.link>

          <.theme_toggle />
        </div>
      </header>

      <main id="app-content" class="mx-auto max-w-[94rem] px-4 pb-24 pt-6 sm:px-6 sm:py-9 lg:px-8">
        {render_slot(@inner_block)}
      </main>

      <.link
        navigate={~p"/import"}
        id="mobile-import"
        class="fixed bottom-5 right-5 z-[800] grid size-14 place-items-center rounded-2xl bg-[var(--accent)] text-[var(--accent-ink)] shadow-xl sm:hidden"
        aria-label="Import OsmAnd export"
      >
        <.icon name="hero-arrow-up-tray" class="size-6" />
      </.link>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  attr :to, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_link(assigns) do
    ~H"""
    <.link
      navigate={@to}
      aria-label={@label}
      aria-current={@active && "page"}
      class={[
        "inline-flex min-h-10 shrink-0 items-center gap-2 rounded-xl px-2.5 text-sm font-semibold transition sm:px-3",
        @active && "bg-[var(--surface-strong)] text-[var(--ink)] shadow-sm ring-1 ring-[var(--line)]",
        !@active && "text-[var(--ink-muted)] hover:bg-[var(--surface)] hover:text-[var(--ink)]"
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span class="hidden md:inline">{@label}</span>
    </.link>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:error}
        title={gettext("Connection lost")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Reconnecting to your analyzer…")}
      </.flash>
      <.flash
        id="server-error"
        kind={:error}
        title={gettext("The analyzer restarted")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Your import is safe. Reconnecting…")}
      </.flash>
    </div>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <button
      id="theme-toggle"
      type="button"
      phx-click={JS.dispatch("phx:cycle-theme")}
      class="grid size-10 shrink-0 place-items-center rounded-xl border border-[var(--line)] bg-[var(--surface)] text-[var(--ink-muted)] transition hover:text-[var(--ink)]"
      aria-label="Change color theme"
    >
      <.icon name="hero-sun" class="size-4 dark:hidden" />
      <.icon name="hero-moon" class="hidden size-4 dark:block" />
    </button>
    """
  end
end
