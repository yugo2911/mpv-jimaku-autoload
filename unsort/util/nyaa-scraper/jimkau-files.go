package main

import (
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"
	"time"
)

// Data structures from Jimaku OpenAPI spec
type FileEntry struct {
	Name string `json:"name"`
}

type Entry struct {
	ID   int64  `json:"id"`
	Name string `json:"name"`
}

// Global client to reuse connections
var client = &http.Client{}

func main() {
	apiKey := "" // Replace with key from /account

	file, err := os.Create("jimaku_filenames.txt")
	if err != nil {
		log.Fatalf("Failed to create file: %v", err)
	}
	defer file.Close()

	// 1. Search for entries (Example: searching for anime)
	searchURL := "https://jimaku.cc/api/entries/search?anime=true"
	var entries []Entry
	err = safeRequest(searchURL, apiKey, &entries)
	if err != nil {
		log.Fatalf("Critical error during search: %v", err)
	}

	// 2. Loop through entries to fetch filenames
	for _, entry := range entries {
		fmt.Printf("Processing: %s\n", entry.Name)

		filesURL := fmt.Sprintf("https://jimaku.cc/api/entries/%d/files", entry.ID)
		var files []FileEntry

		err := safeRequest(filesURL, apiKey, &files)
		if err != nil {
			fmt.Printf("Skipping entry %d due to error: %v\n", entry.ID, err)
			continue
		}

		// 3. Write filenames to text file
		for _, f := range files {
			file.WriteString(f.Name + "\n")
		}
	}

	fmt.Println("Scraping complete. Results in jimaku_filenames.txt")
}

// safeRequest handles authentication and automatic pausing for rate limits
func safeRequest(url string, auth string, target interface{}) error {
	for {
		req, _ := http.NewRequest("GET", url, nil)
		req.Header.Set("Authorization", auth)

		resp, err := client.Do(req)
		if err != nil {
			return err
		}
		defer resp.Body.Close()

		// Handle Rate Limit (HTTP 429)
		if resp.StatusCode == 429 {
			resetAfter := resp.Header.Get("x-ratelimit-reset-after") //
			seconds, _ := strconv.ParseFloat(resetAfter, 64)

			fmt.Printf("Rate limit hit. Sleeping for %.2f seconds...\n", seconds)
			time.Sleep(time.Duration(seconds * float64(time.Second)))
			continue // Retry the request after sleeping
		}

		if resp.StatusCode != 200 {
			return fmt.Errorf("server returned status %d", resp.StatusCode)
		}

		return json.NewDecoder(resp.Body).Decode(target)
	}
}
