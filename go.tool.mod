// How to use https://www.alexedwards.net/blog/how-to-manage-tool-dependencies-in-go-1.24-plus
module example/foo/bar

go 1.25.0

tool (
	github.com/segmentio/golines
	golang.org/x/vuln/cmd/govulncheck
	honnef.co/go/tools/cmd/staticcheck
	mvdan.cc/gofumpt
)

require (
	github.com/BurntSushi/toml v1.5.0 // indirect
	github.com/alecthomas/template v0.0.0-20190718012654-fb15b899a751 // indirect
	github.com/alecthomas/units v0.0.0-20240927000941-0f3dac36c52b // indirect
	github.com/dave/dst v0.27.3 // indirect
	github.com/fatih/structtag v1.2.0 // indirect
	github.com/google/go-cmp v0.7.0 // indirect
	github.com/hpcloud/tail v1.0.0 // indirect
	github.com/mattn/go-colorable v0.1.14 // indirect
	github.com/mattn/go-isatty v0.0.20 // indirect
	github.com/mgutz/ansi v0.0.0-20200706080929-d51e80ef957d // indirect
	github.com/pmezard/go-difflib v1.0.0 // indirect
	github.com/segmentio/golines v0.12.2 // indirect
	github.com/sirupsen/logrus v1.9.3 // indirect
	github.com/x-cray/logrus-prefixed-formatter v0.5.2 // indirect
	golang.org/x/crypto v0.41.0 // indirect
	golang.org/x/exp/typeparams v0.0.0-20250813145105-42675adae3e6 // indirect
	golang.org/x/mod v0.27.0 // indirect
	golang.org/x/sync v0.16.0 // indirect
	golang.org/x/sys v0.35.0 // indirect
	golang.org/x/telemetry v0.0.0-20250815182358-98dc7c9adeb6 // indirect
	golang.org/x/term v0.34.0 // indirect
	golang.org/x/tools v0.36.0 // indirect
	golang.org/x/vuln v1.1.4 // indirect
	gopkg.in/alecthomas/kingpin.v2 v2.2.6 // indirect
	gopkg.in/fsnotify.v1 v1.4.7 // indirect
	gopkg.in/tomb.v1 v1.0.0-20141024135613-dd632973f1e7 // indirect
	honnef.co/go/tools v0.6.1 // indirect
	mvdan.cc/gofumpt v0.8.0 // indirect
)
