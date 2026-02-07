package main

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/app"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
)

func main() {
	// Create a new Fyne application
	myApp := app.New()

	// Create the display window (shows text, read-only)
	displayWindow := myApp.NewWindow("Display Window")

	// Create multiple display labels (one for each tab)
	numTabs := 5
	displayLabels := make([]*widget.Label, numTabs)
	for i := 0; i < numTabs; i++ {
		displayLabels[i] = widget.NewLabel("Text will appear here...")
		displayLabels[i].Wrapping = fyne.TextWrapWord
		displayLabels[i].Alignment = fyne.TextAlignLeading
	}

	// Create label to show current tab number in display window
	displayTabLabel := widget.NewLabel("Tab 1 of 5")

	// Create container for the current display label (will be updated)
	currentDisplayContainer := container.NewMax(displayLabels[0])

	displayContent := container.NewVBox(
		widget.NewLabel("Display Window (Read-only)"),
		widget.NewSeparator(),
		displayTabLabel,
		currentDisplayContainer,
	)
	displayWindow.SetContent(displayContent)
	displayWindow.Resize(fyne.NewSize(400, 300))

	// Create the input window (for entering text)
	inputWindow := myApp.NewWindow("Input Window")

	// Create multiple input entries (tabs)
	inputEntries := make([]*widget.Entry, numTabs)
	for i := 0; i < numTabs; i++ {
		inputEntries[i] = widget.NewMultiLineEntry()
		inputEntries[i].SetPlaceHolder("Type something here...")
	}

	// Track current tab index
	currentTab := 0

	// Create label to show current tab number
	tabLabel := widget.NewLabel("Tab 1 of 5")

	// Create container for the current input (will be updated)
	currentInputContainer := container.NewMax(inputEntries[currentTab])

	// Function to update the displayed tab
	updateTab := func() {
		tabLabel.SetText(fmt.Sprintf("Tab %d of %d", currentTab+1, numTabs))
		displayTabLabel.SetText(fmt.Sprintf("Tab %d of %d", currentTab+1, numTabs))
		currentInputContainer.Objects = []fyne.CanvasObject{inputEntries[currentTab]}
		currentInputContainer.Refresh()
		currentDisplayContainer.Objects = []fyne.CanvasObject{displayLabels[currentTab]}
		currentDisplayContainer.Refresh()
	}

	// Create navigation buttons
	leftButton := widget.NewButton("←", func() {
		if currentTab > 0 {
			currentTab--
			updateTab()
		}
	})

	rightButton := widget.NewButton("→", func() {
		if currentTab < numTabs-1 {
			currentTab++
			updateTab()
		}
	})

	navigationContainer := container.NewHBox(
		leftButton,
		tabLabel,
		rightButton,
	)

	// Create Send button
	sendButton := widget.NewButton("Send", func() {
		displayLabels[currentTab].SetText(inputEntries[currentTab].Text)
	})

	// Create Kill button
	killButton := widget.NewButton("Kill", func() {
		myApp.Quit()
	})

	// Create button container
	buttonContainer := container.NewHBox(
		sendButton,
		killButton,
	)

	inputContent := container.NewVBox(
		widget.NewLabel("Input Window - Type here:"),
		widget.NewSeparator(),
		navigationContainer,
		currentInputContainer,
		buttonContainer,
	)
	inputWindow.SetContent(inputContent)
	inputWindow.Resize(fyne.NewSize(400, 300))

	// Show both windows
	displayWindow.Show()
	inputWindow.Show()

	// Run the application
	myApp.Run()
}
