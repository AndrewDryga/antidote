decode_jobs = %{
  "Antidote" => &Antidote.decode!/1,
  "Poison"   => &Poison.decode!/1,
  # "JSX"      => &JSX.decode!(&1, [:strict]),
  # "Tiny"     => &Tiny.decode!/1,
  # "jsone"    => &:jsone.decode/1,
  "jiffy"    => &:jiffy.decode(&1, [:return_maps]),
  # "JSON"     => &JSON.decode!/1,
}

decode_inputs = [
  "GitHub",
  # "Giphy",
  # "GovTrack",
  # "Blockchain",
  # "Pokedex",
  "JSON Generator",
  # "JSON Generator (Pretty)",
  "UTF-8 escaped",
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

Benchee.run(decode_jobs,
  parallel: 4,
  # warmup: 5,
  # time: 30,
  inputs: for name <- decode_inputs, into: %{} do
    name
    |> read_data.()
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
