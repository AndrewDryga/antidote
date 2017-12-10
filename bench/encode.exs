encode_jobs = %{
  "Antidote"        => &Antidote.encode_to_iodata!/1,
  "Antidote strict" => &Antidote.encode_to_iodata!(&1, maps: :strict),
  "Poison"          => &Poison.encode_to_iodata!/1,
  "JSX"             => &JSX.encode!/1,
  "Tiny"            => &Tiny.encode!/1,
  "jsone"           => &:jsone.encode/1,
  "jiffy"           => &:jiffy.encode/1,
  "JSON"            => &JSON.encode!/1,
}

encode_inputs = [
  "GitHub",
  "Giphy",
  "GovTrack",
  "Blockchain",
  "Pokedex",
  "JSON Generator",
  "UTF-8 unescaped",
  "Issue 90",
]

read_data = fn (name) ->
  name
  |> String.downcase
  |> String.replace(~r/([^\w]|-|_)+/, "-")
  |> String.trim("-")
  |> (&"data/#{&1}.json").()
  |> Path.expand(__DIR__)
  |> File.read!
end

path = System.get_env("BENCHMARKS_OUTPUT_PATH") || raise "I DON'T KNOW WHERE TO WRITE!!!"
file = Path.join(path, "decode.json")

Benchee.run(encode_jobs,
  parallel: 4,
  # warmup: 5,
  # time: 30,
  inputs: for name <- encode_inputs, into: %{} do
            name
            |> read_data.()
            |> Poison.decode!
            |> (&{name, &1}).()
          end,
  formatters: [
    Benchee.Formatters.JSON
  ],
  formatter_options: [
    json: [
      file: file
    ]
  ]
)
