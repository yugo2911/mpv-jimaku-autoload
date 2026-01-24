package main

import (
	"fmt"
	"log"
	"os"
	"strings"

	"github.com/gocolly/colly/v2"
)

var videoExt = []string{
	".mkv", ".mp4", ".avi", ".mov", ".wmv",
	".flv", ".webm", ".mpg", ".mpeg",
}

func isVideo(title string) bool {
	lower := strings.ToLower(title)
	for _, ext := range videoExt {
		if strings.Contains(lower, ext) {
			return true
		}
	}
	return false
}

func main() {
	file, err := os.Create("torrents.txt")
	if err != nil {
		log.Fatalf("Failed to create file: %v", err)
	}
	defer file.Close()

	c := colly.NewCollector(
		colly.UserAgent("Mozilla/5.0"),
		colly.AllowedDomains("www.tokyo-tosho.net", "tokyo-tosho.net"),
	)

	// Extract full torrent names
	c.OnHTML("td.desc-top a", func(e *colly.HTMLElement) {
		title := e.Text
		if title != "" && isVideo(title) {
			file.WriteString(title + "\n")
			fmt.Println(title)
		}
	})

	c.OnError(func(r *colly.Response, err error) {
		log.Printf("Error: %v", err)
	})

	const maxPages = 300

	for page := 1; page <= maxPages; page++ {
		url := fmt.Sprintf("https://www.tokyo-tosho.net/?cat=1&page=%d", page)
		fmt.Println("Visiting:", url)
		_ = c.Visit(url)
		c.Wait()
	}
}
