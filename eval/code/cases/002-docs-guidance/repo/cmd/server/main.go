package main

import (
	"fmt"
	"log"
	"net/http"

	"github.com/example/notify/internal/notify"
)

func main() {
	svc := notify.NewService()

	http.HandleFunc("/send", func(w http.ResponseWriter, r *http.Request) {
		channel := r.URL.Query().Get("channel")
		msg := r.URL.Query().Get("msg")
		if err := svc.Send(channel, msg); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		fmt.Fprintln(w, "sent")
	})

	log.Println("listening on :8080")
	log.Fatal(http.ListenAndServe(":8080", nil))
}
