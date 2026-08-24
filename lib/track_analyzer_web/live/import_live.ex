defmodule TrackAnalyzerWeb.ImportLive do
  use TrackAnalyzerWeb, :live_view

  alias TrackAnalyzer.Imports

  @max_archive_bytes 5 * 1024 * 1024 * 1024

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Imports.subscribe()

    {:ok,
     socket
     |> assign(:page_title, "Import OsmAnd exports")
     |> assign(:batch, nil)
     |> assign(:form, to_form(%{}, as: :import))
     |> stream(:archives, Imports.list_recent_archives(12))
     |> allow_upload(:archives,
       accept: ~w(.osf),
       max_entries: 25,
       max_file_size: @max_archive_bytes,
       chunk_size: 1024 * 1024,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  defp handle_progress(:archives, entry, socket) when entry.done? do
    {batch, socket} = ensure_batch(socket)

    result =
      consume_uploaded_entry(socket, entry, fn %{path: path} ->
        {:ok, Imports.accept_archive(batch, path, entry.client_name)}
      end)

    case result do
      {:ok, archive} ->
        {:noreply,
         socket
         |> stream_insert(:archives, archive, at: 0)
         |> put_flash(:info, "#{entry.client_name} is safely stored and queued.")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not store #{entry.client_name}: #{inspect(reason)}")}
    end
  end

  defp handle_progress(:archives, _entry, socket), do: {:noreply, socket}

  @impl true
  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :archives, ref)}
  end

  def handle_event("finish", _params, %{assigns: %{batch: nil}} = socket) do
    {:noreply, put_flash(socket, :error, "Choose at least one OsmAnd .osf export first.")}
  end

  def handle_event("finish", _params, socket) do
    {:ok, batch} = Imports.finish_upload(socket.assigns.batch)

    {:noreply,
     socket
     |> assign(:batch, batch)
     |> put_flash(:info, "Import is running in the background. You can leave this page safely.")}
  end

  @impl true
  def handle_info({:archive_updated, archive}, socket) do
    {:noreply, stream_insert(socket, :archives, archive, at: 0)}
  end

  def handle_info({:batch_updated, batch}, %{assigns: %{batch: %{id: id}}} = socket)
      when batch.id == id do
    {:noreply, assign(socket, :batch, batch)}
  end

  def handle_info({:batch_updated, _batch}, socket), do: {:noreply, socket}

  def handle_info({:track_updated, _track}, socket), do: {:noreply, socket}

  defp ensure_batch(%{assigns: %{batch: nil}} = socket) do
    {:ok, batch} = Imports.create_batch()
    {batch, assign(socket, :batch, batch)}
  end

  defp ensure_batch(socket), do: {socket.assigns.batch, socket}

  defp upload_error(:too_large), do: "This export exceeds the 5 GB safety limit."
  defp upload_error(:too_many_files), do: "Upload at most 25 exports in one batch."
  defp upload_error(:not_accepted), do: "Only OsmAnd .osf exports are accepted."
  defp upload_error(error), do: inspect(error)

  defp file_size(bytes) when bytes >= 1024 * 1024 * 1024,
    do: :erlang.float_to_binary(bytes / (1024 * 1024 * 1024), decimals: 1) <> " GB"

  defp file_size(bytes) when bytes >= 1024 * 1024,
    do: :erlang.float_to_binary(bytes / (1024 * 1024), decimals: 1) <> " MB"

  defp file_size(bytes), do: "#{round(bytes / 1024)} KB"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={nil} active="import">
      <section id="import-page" class="mx-auto max-w-6xl">
        <header id="import-header" class="grid items-center gap-5 lg:grid-cols-[1fr_auto]">
          <div>
            <h1 class="text-3xl font-black tracking-[-0.045em] sm:text-4xl">
              Import OsmAnd exports
            </h1>
            <p class="mt-2 max-w-2xl text-sm leading-6 text-[var(--ink-muted)]">
              Upload one or more <strong class="text-[var(--ink)]">.osf</strong>
              files. Tracks are validated, deduplicated, and analyzed in the background.
            </p>
          </div>
          <div class="flex items-center gap-3 rounded-2xl border border-[var(--line)] bg-[var(--surface)] px-4 py-3 text-xs text-[var(--ink-muted)]">
            <.icon name="hero-lock-closed" class="size-5 text-emerald-600" /><span><strong class="block text-[var(--ink)]">Analysis stays local</strong>No enrichment APIs enabled</span>
          </div>
        </header>

        <.form for={@form} id="osf-upload-form" phx-change="validate" phx-submit="finish" class="mt-6">
          <div
            id="osf-dropzone"
            phx-drop-target={@uploads.archives.ref}
            class={[
              "topo-card group relative overflow-hidden rounded-[2rem] border-2 border-dashed p-6 transition duration-300 sm:p-10",
              @uploads.archives.entries == [] &&
                "border-[var(--line)] hover:-translate-y-0.5 hover:border-[var(--accent-strong)]",
              @uploads.archives.entries != [] && "border-[var(--accent-strong)]"
            ]}
          >
            <div class="contour-pattern absolute inset-0 opacity-55"></div>
            <div class="relative grid gap-8 lg:grid-cols-[0.8fr_1.2fr] lg:items-center">
              <div class="text-center lg:text-left">
                <span class="mx-auto grid size-16 place-items-center rounded-2xl bg-[var(--accent)] text-[var(--accent-ink)] shadow-lg transition duration-300 group-hover:-rotate-3 group-hover:scale-105 lg:mx-0"><.icon
                  name="hero-folder-arrow-down"
                  class="size-8"
                /></span>
                <h2 class="mt-5 text-2xl font-black tracking-[-0.035em]">Drop OsmAnd exports here</h2>
                <p class="mt-2 text-sm leading-6 text-[var(--ink-muted)]">
                  Up to 25 OSF files per batch, 5 GB each. The browser can be closed once each upload reaches 100%.
                </p>
                <label
                  for={@uploads.archives.ref}
                  class="mt-5 inline-flex min-h-11 cursor-pointer items-center gap-2 rounded-xl bg-[var(--ink)] px-4 py-2 text-sm font-bold text-[var(--canvas)] shadow-sm transition hover:-translate-y-0.5"
                >
                  <.icon name="hero-plus" class="size-4" /> Choose .osf files
                </label>
                <.live_file_input upload={@uploads.archives} class="sr-only" />
              </div>

              <div id="upload-entries" class="space-y-3">
                <div
                  :if={@uploads.archives.entries == []}
                  id="upload-empty"
                  class="rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)]/70 p-5"
                >
                  <div class="grid grid-cols-3 gap-3 text-center">
                    <.process_step number="01" label="Validate OSF" />
                    <.process_step number="02" label="Extract + dedupe" />
                    <.process_step number="03" label="Analyze in parallel" />
                  </div>
                </div>
                <article
                  :for={entry <- @uploads.archives.entries}
                  id={"upload-#{entry.ref}"}
                  class="rounded-2xl border border-[var(--line)] bg-[var(--surface-strong)] p-4 shadow-sm"
                >
                  <div class="flex items-start gap-3">
                    <span class="grid size-10 shrink-0 place-items-center rounded-xl bg-[color-mix(in_srgb,var(--accent)_30%,transparent)]"><.icon
                      name="hero-archive-box"
                      class="size-5"
                    /></span>
                    <div class="min-w-0 flex-1">
                      <p class="truncate text-sm font-bold">{entry.client_name}</p><p class="mt-1 text-xs text-[var(--ink-muted)]">
                        {file_size(entry.client_size)} · {entry.progress}% uploaded
                      </p>
                    </div>
                    <button
                      type="button"
                      id={"cancel-upload-#{entry.ref}"}
                      phx-click="cancel-upload"
                      phx-value-ref={entry.ref}
                      class="grid size-9 place-items-center rounded-lg text-[var(--ink-muted)] hover:bg-red-500/10 hover:text-red-600"
                      aria-label="Cancel upload"
                    ><.icon name="hero-x-mark" class="size-5" /></button>
                  </div>
                  <div class="mt-3 h-2 overflow-hidden rounded-full bg-[var(--line)]">
                    <div
                      class="h-full rounded-full bg-[var(--accent-strong)] transition-all duration-300"
                      style={"width: #{entry.progress}%"}
                    >
                    </div>
                  </div>
                  <p
                    :for={error <- upload_errors(@uploads.archives, entry)}
                    class="mt-2 text-xs font-semibold text-red-600"
                  >
                    {upload_error(error)}
                  </p>
                </article>
                <p
                  :for={error <- upload_errors(@uploads.archives)}
                  class="rounded-xl bg-red-500/10 px-3 py-2 text-sm font-semibold text-red-600"
                >
                  {upload_error(error)}
                </p>
              </div>
            </div>
          </div>

          <div class="mt-4 flex flex-wrap items-center justify-between gap-3">
            <p class="text-xs text-[var(--ink-muted)]">
              <.icon name="hero-information-circle" class="mr-1 inline size-4" />OSF is a ZIP container; loose GPX uploads are intentionally rejected.
            </p>
            <.button id="finish-import" type="submit" variant="primary" disabled={@batch == nil}>
              Continue in background <.icon name="hero-arrow-right" class="size-4" />
            </.button>
          </div>
        </.form>

        <section class="mt-10">
          <div class="mb-4 flex items-end justify-between gap-4">
            <div>
              <p class="text-xs font-bold uppercase tracking-[0.17em] text-[var(--ink-muted)]">
                Live processing dock
              </p><h2 class="mt-1 text-2xl font-black tracking-[-0.035em]">Recent exports</h2>
            </div><.link
              navigate={~p"/tracks"}
              class="text-sm font-bold text-[var(--ink-muted)] hover:text-[var(--ink)]"
            >View tracks →</.link>
          </div>
          <div id="import-archives" phx-update="stream" class="grid gap-4 lg:grid-cols-2">
            <div
              id="import-archives-empty"
              class="hidden only:block rounded-2xl border border-dashed border-[var(--line)] p-8 text-center text-sm text-[var(--ink-muted)]"
            >
              Uploaded exports will remain visible here.
            </div>
            <article
              :for={{id, archive} <- @streams.archives}
              id={id}
              class="topo-card rounded-2xl p-5"
            >
              <div class="flex items-start justify-between gap-4">
                <div class="min-w-0">
                  <p class="truncate font-black">{archive.original_filename}</p><p class="mt-1 text-xs text-[var(--ink-muted)]">
                    {archive.stage}
                  </p>
                </div><span class={[
                  "shrink-0 rounded-full px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider ring-1",
                  status_classes(archive.status)
                ]}>{status_label(archive.status)}</span>
              </div>
              <div class="mt-4 h-2 overflow-hidden rounded-full bg-[var(--line)]">
                <div
                  class="h-full rounded-full bg-[var(--accent-strong)] transition-all duration-500"
                  style={"width: #{archive.progress}%"}
                >
                </div>
              </div>
              <div class="mt-4 grid grid-cols-4 gap-2 text-center">
                <.archive_count label="Tracks" value={archive.item_count} /><.archive_count
                  label="Ready"
                  value={archive.complete_count}
                /><.archive_count label="Dupes" value={archive.duplicate_count} /><.archive_count
                  label="Issues"
                  value={archive.failed_count}
                />
              </div>
              <p
                :if={archive.error}
                class="mt-3 rounded-xl bg-red-500/10 px-3 py-2 text-xs text-red-600"
              >
                {archive.error}
              </p>
              <p
                :if={archive.warning}
                class="mt-3 rounded-xl bg-amber-500/10 px-3 py-2 text-xs text-amber-700 dark:text-amber-300"
              >
                {archive.warning}
              </p>
            </article>
          </div>
        </section>
      </section>
    </Layouts.app>
    """
  end

  attr :number, :string, required: true
  attr :label, :string, required: true

  defp process_step(assigns) do
    ~H"""
    <div>
      <span class="mx-auto grid size-9 place-items-center rounded-full border border-[var(--line)] bg-[var(--surface)] text-[10px] font-black text-[var(--ink-muted)]">{@number}</span><p class="mt-2 text-xs font-bold">
        {@label}
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :value, :integer, required: true

  defp archive_count(assigns) do
    ~H"""
    <div>
      <p class="metric-number text-lg font-black">{@value}</p><p class="text-[10px] uppercase tracking-wider text-[var(--ink-muted)]">
        {@label}
      </p>
    </div>
    """
  end
end
