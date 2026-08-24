defmodule TrackAnalyzerWeb.CoreComponents do
  @moduledoc "Tailwind-native interface primitives shared across the application."

  use Phoenix.Component
  use Gettext, backend: TrackAnalyzerWeb.Gettext

  alias Phoenix.LiveView.JS

  attr :id, :string
  attr :flash, :map, default: %{}
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error]
  attr :rest, :global
  slot :inner_block

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={message = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed right-4 top-4 z-[1000] w-[min(24rem,calc(100vw-2rem))]"
      {@rest}
    >
      <div class={[
        "topo-card flex items-start gap-3 rounded-2xl px-4 py-3 text-sm",
        @kind == :info && "border-cyan-400/30",
        @kind == :error && "border-red-400/30"
      ]}>
        <.icon
          name={if(@kind == :info, do: "hero-information-circle", else: "hero-exclamation-circle")}
          class="mt-0.5 size-5 shrink-0"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="font-semibold">{@title}</p>
          <p class="text-[var(--ink-muted)]">{message}</p>
        </div>
        <button
          type="button"
          class="cursor-pointer opacity-50 transition hover:opacity-100"
          aria-label={gettext("close")}
        >
          <.icon name="hero-x-mark" class="size-5" />
        </button>
      </div>
    </div>
    """
  end

  attr :rest, :global, include: ~w(href navigate patch method download name value disabled type)
  attr :class, :any, default: nil
  attr :variant, :string, values: ~w(primary subtle danger), default: "subtle"
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    assigns =
      assign(assigns, :classes, [
        "inline-flex min-h-11 items-center justify-center gap-2 rounded-xl px-4 py-2 text-sm font-semibold transition duration-200 disabled:cursor-not-allowed disabled:opacity-50",
        button_variant(assigns.variant),
        assigns.class
      ])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@classes} {@rest}>{render_slot(@inner_block)}</.link>
      """
    else
      ~H"""
      <button class={@classes} {@rest}>{render_slot(@inner_block)}</button>
      """
    end
  end

  defp button_variant("primary"),
    do: "bg-[var(--ink)] text-[var(--canvas)] shadow-sm hover:-translate-y-0.5 hover:shadow-lg"

  defp button_variant("danger"), do: "bg-red-600 text-white hover:bg-red-700"

  defp button_variant(_variant),
    do: "border border-[var(--line)] bg-[var(--surface-strong)] hover:border-[var(--ink-muted)]"

  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values:
      ~w(checkbox color date datetime-local email file month number password search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField
  attr :errors, :list, default: []
  attr :checked, :boolean
  attr :prompt, :string, default: nil
  attr :options, :list
  attr :multiple, :boolean, default: false
  attr :class, :any, default: nil
  attr :error_class, :any, default: nil

  attr :rest, :global,
    include:
      ~w(accept autocomplete capture cols disabled form list max maxlength min minlength multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error/1))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-3">
      <label for={@id} class="flex cursor-pointer items-center gap-2 text-sm font-medium">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "size-4 rounded border-[var(--line)] accent-[var(--accent-strong)]"}
          {@rest}
        />
        {@label}
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id} class="block">
        <.input_label label={@label} />
        <select
          id={@id}
          name={@name}
          class={[input_class(@class), @errors != [] && (@error_class || "border-red-500")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id} class="block">
        <.input_label label={@label} />
        <textarea
          id={@id}
          name={@name}
          class={[
            input_class(@class),
            "min-h-28",
            @errors != [] && (@error_class || "border-red-500")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id} class="block">
        <.input_label label={@label} />
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[input_class(@class), @errors != [] && (@error_class || "border-red-500")]}
          {@rest}
        />
      </label>
      <.error :for={message <- @errors}>{message}</.error>
    </div>
    """
  end

  attr :label, :string, default: nil

  defp input_label(assigns) do
    ~H"""
    <span
      :if={@label}
      class="mb-1.5 block text-xs font-semibold uppercase tracking-[0.14em] text-[var(--ink-muted)]"
    >{@label}</span>
    """
  end

  defp input_class(nil) do
    "w-full rounded-xl border border-[var(--line)] bg-[var(--surface-strong)] px-3 py-2.5 text-sm text-[var(--ink)] shadow-sm transition placeholder:text-[var(--ink-muted)] focus:border-[var(--accent-strong)]"
  end

  defp input_class(class), do: class

  slot :inner_block, required: true

  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex items-center gap-2 text-sm text-red-600 dark:text-red-300">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _rest} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300", "opacity-0 translate-y-4 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:scale-95"}
    )
  end

  def translate_error({message, options}) do
    if count = options[:count] do
      Gettext.dngettext(TrackAnalyzerWeb.Gettext, "errors", message, message, count, options)
    else
      Gettext.dgettext(TrackAnalyzerWeb.Gettext, "errors", message, options)
    end
  end

  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {message, options}} <- errors, do: translate_error({message, options})
  end
end
