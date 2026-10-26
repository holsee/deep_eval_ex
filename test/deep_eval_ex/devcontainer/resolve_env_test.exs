defmodule DeepEvalEx.Devcontainer.ResolveEnvTest do
  # Exercises .devcontainer/resolve-env.sh against a copy of the script in a
  # temp dir, so the developer's real .devcontainer/.env is never read or
  # touched. The real 1Password CLI is never invoked: PATH only ever holds
  # the tools the script needs, plus a stub `op` where a test asks for one.
  use ExUnit.Case, async: true

  @root Path.expand("../../..", __DIR__)
  @script Path.join(@root, ".devcontainer/resolve-env.sh")
  @tools ~w(sh dirname touch grep cp mktemp chmod mv rm cat)

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    dir = Path.join(tmp_dir, ".devcontainer")
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(dir)
    File.mkdir_p!(bin)
    File.cp!(@script, Path.join(dir, "resolve-env.sh"))

    for tool <- @tools do
      File.ln_s!(System.find_executable(tool), Path.join(bin, tool))
    end

    %{dir: dir, bin: bin}
  end

  test "copies plain literals verbatim despite a commented op:// placeholder",
       %{dir: dir} = ctx do
    source = """
    # Values may be 1Password references, e.g.
    #   OPENAI_API_KEY=op://<vault>/<item>/credential
    OPENAI_API_KEY=sk-literal
    ANTHROPIC_API_KEY=
    """

    File.write!(Path.join(dir, ".env"), source)

    assert {_, 0} = run(ctx)
    assert File.read!(resolved(dir)) == source
    assert mode(resolved(dir)) == 0o600
  end

  test "tightens a pre-existing world-readable resolved file to 0600", %{dir: dir} = ctx do
    File.write!(Path.join(dir, ".env"), "OPENAI_API_KEY=sk-literal\n")
    File.write!(resolved(dir), "stale\n")
    File.chmod!(resolved(dir), 0o644)

    assert {_, 0} = run(ctx)
    assert File.read!(resolved(dir)) == "OPENAI_API_KEY=sk-literal\n"
    assert mode(resolved(dir)) == 0o600
  end

  test "fails without writing a resolved file when op:// is used but op is missing",
       %{dir: dir} = ctx do
    File.write!(Path.join(dir, ".env"), "OPENAI_API_KEY=op://vault/item/credential\n")

    assert {output, status} = run(ctx)
    assert status != 0
    assert output =~ "1Password CLI (op) is not installed"
    refute File.exists?(resolved(dir))
  end

  test "leaves no partial resolved file or temp file when op inject fails",
       %{dir: dir, bin: bin} = ctx do
    File.write!(Path.join(dir, ".env"), "OPENAI_API_KEY=op://vault/item/credential\n")
    File.write!(resolved(dir), "previous\n")

    # Stub `op` that writes half a file to its --out-file and then fails.
    stub = Path.join(bin, "op")

    File.write!(stub, """
    #!/bin/sh
    while [ $# -gt 0 ]; do
      if [ "$1" = "--out-file" ]; then printf 'OPENAI_API_KEY=' > "$2"; fi
      shift
    done
    echo "op: item not found" >&2
    exit 1
    """)

    File.chmod!(stub, 0o755)

    assert {output, status} = run(ctx)
    assert status != 0
    assert output =~ "item not found"
    assert File.read!(resolved(dir)) == "previous\n"
    assert File.ls!(dir) |> Enum.sort() == [".env", ".env.resolved", "resolve-env.sh"]
  end

  test "removes the temp file when interrupted mid-resolve", %{dir: dir, bin: bin} = ctx do
    File.write!(Path.join(dir, ".env"), "OPENAI_API_KEY=op://vault/item/credential\n")
    # Stands in for Ctrl-C at the 1Password prompt: op signals the script.
    File.write!(Path.join(bin, "op"), "#!/bin/sh\nkill -TERM $PPID\n")
    File.chmod!(Path.join(bin, "op"), 0o755)

    {_output, status} = run(ctx)

    assert status != 0
    assert File.ls!(dir) |> Enum.sort() == [".env", "resolve-env.sh"]
  end

  test "gitignores the resolved file and its temp files", %{tmp_dir: tmp_dir} do
    repo = ignore_repo(tmp_dir)

    for path <-
          ~w(.devcontainer/.env .devcontainer/.env.resolved .devcontainer/.env.resolved.Ab12Cd) do
      assert {_, 0} = git(repo, ["check-ignore", "-q", path]), "#{path} is not ignored"
    end
  end

  # The repository itself when it is a git checkout. Outside one (a tarball
  # or `git archive` copy) there is no .git to ask, so its .gitignore is
  # checked in a fresh repository instead.
  defp ignore_repo(tmp_dir) do
    case git(@root, ["rev-parse", "--show-toplevel"]) do
      {top, 0} when is_binary(top) ->
        if Path.expand(String.trim(top)) == @root, do: @root, else: scratch_repo(tmp_dir)

      _not_a_checkout ->
        scratch_repo(tmp_dir)
    end
  end

  defp scratch_repo(tmp_dir) do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    {_, 0} = git(repo, ["init", "-q"])
    File.cp!(Path.join(@root, ".gitignore"), Path.join(repo, ".gitignore"))
    repo
  end

  # The developer's global excludes must not make an unignored path pass.
  defp git(dir, args) do
    System.cmd("git", ["-c", "safe.directory=*", "-c", "core.excludesFile=/dev/null" | args],
      cd: dir,
      stderr_to_stdout: true
    )
  end

  defp run(%{dir: dir, bin: bin}) do
    System.cmd(Path.join(bin, "sh"), [Path.join(dir, "resolve-env.sh")],
      env: [{"PATH", bin}],
      stderr_to_stdout: true
    )
  end

  defp resolved(dir), do: Path.join(dir, ".env.resolved")

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)
end
