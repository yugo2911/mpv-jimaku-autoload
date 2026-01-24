package main

import (
	"fmt"
	"log"
	"os"

	"github.com/gocolly/colly/v2"
)

func main() {
	// Output file
	file, err := os.Create("torrents.txt")
	if err != nil {
		log.Fatalf("Failed to create file: %v", err)
	}
	defer file.Close()

	c := colly.NewCollector(
		colly.UserAgent("Mozilla/5.0"),
		colly.AllowedDomains("nyaa.land"),
	)

	// Extract torrent names
	c.OnHTML("table tbody tr", func(e *colly.HTMLElement) {
		title := e.ChildText("td:nth-child(2) a[href^='/view']")
		if title != "" {
			file.WriteString(title + "\n")
			fmt.Println(title)
		}
	})

	c.OnError(func(r *colly.Response, err error) {
		log.Printf("Error: %v", err)
	})

	// Loop pages manually
	const maxPages = 10 // change this to whatever you want

	for page := 1; page <= maxPages; page++ {
		url := fmt.Sprintf("https://nyaa.land/?f=0&c=1_0&q=&p=%d", page)
		fmt.Println("Visiting:", url)
		err := c.Visit(url)
		if err != nil {
			log.Printf("Visit error: %v", err)
		}
		c.Wait()
	}
}
