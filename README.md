# Poke GUI

A cross-platform GUI application built with Go and Fyne.

## Project Structure

- [main.go](main.go) - Main application entry point with a basic Fyne GUI
- [FyneApp.toml](FyneApp.toml) - Application metadata for building and packaging
- [go.mod](go.mod) - Go module dependencies

## System Dependencies

### Linux (Debian/Ubuntu)
```bash
sudo apt-get install gcc libgl1-mesa-dev xorg-dev
```

### Linux (Fedora/RHEL)
```bash
sudo dnf install gcc libX11-devel libXcursor-devel libXrandr-devel libXinerama-devel mesa-libGL-devel libXi-devel libXxf86vm-devel
```

### macOS
Install Xcode command line tools:
```bash
xcode-select --install
```

### Windows
Install TDM-GCC from https://jmeubank.github.io/tdm-gcc/ or MinGW-w64

## Building and Running

### Run the application
```bash
go run main.go
```

### Build executable
```bash
go build -o poke-gui
./poke-gui
```

### Build with Fyne tools (for packaging)
```bash
go install fyne.io/fyne/v2/cmd/fyne@latest
fyne package
```

## Features

The application creates two separate windows:

1. **Input Window** - Features 5 separate input tabs, each with its own text entry field. Navigate between tabs using arrow buttons.
2. **Display Window** - Features 5 corresponding display tabs that sync with the input window tabs.

**Controls:**
- **← / → buttons** - Navigate between different tabs (5 tabs total). Both windows switch tabs together.
- **Send button** - Transfers text from the current input tab to the corresponding display tab
- **Kill button** - Closes the entire application (both windows)

Each tab pair (input/display) maintains its own independent content.

## Development

The application demonstrates:
- Multi-window applications
- Real-time text synchronization between windows
- Multi-line text entries and labels
- Text wrapping and alignment
- Container layouts with separators

Modify [main.go](main.go) to add more features and customize the GUI.

## Resources

- [Fyne Documentation](https://docs.fyne.io/)
- [Fyne Widgets](https://docs.fyne.io/widget/)
- [Fyne Examples](https://github.com/fyne-io/examples)
