// Copyright 2019 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// [START cloudrun_pubsub_server]

// Sample run-pubsub is a Cloud Run service which handles Pub/Sub messages.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"

	gomail "gopkg.in/mail.v2"
)

const (
	mailFrom = "cs-pubsub-test@google.com"
	mailTo   = "cs-pubsub-test@google.com"
	mailHost = "smtp.gmail.com"
	mailPort = 465

	mailUsernameKey = "MAIL_USER"
	mailPasswordKey = "MAIL_PASSWD"
)

func main() {
	http.HandleFunc("/", sendMail)
	// Determine port for HTTP service.
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
		log.Printf("Defaulting to port %s", port)
	}
	// Start HTTP server.
	log.Printf("Listening on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

// [END cloudrun_pubsub_server]

// [START cloudrun_pubsub_handler]

// PubSubMessage is the payload of a Pub/Sub event.
// See the documentation for more details:
// https://cloud.google.com/pubsub/docs/reference/rest/v1/PubsubMessage
type PubSubMessage struct {
	Message struct {
		Data []byte `json:"data,omitempty"`
		ID   string `json:"id"`
	} `json:"message"`
	Subscription string `json:"subscription"`
}

type ConfigSyncMessage struct {
	ProjectID   string `json:"projectID"`
	ClusterName string `json:"clusterName"`
	NodeName    string `json:"nodeName"`
	Topic       string `json:"topic"`
	RSNamespace string `json:"RSNamespace"`
	RSName      string `json:"RSName"`
	Commit      string `json:"commit,omitempty"`
	Status      string `json:"status"`
	Error       string `json:"error,omitempty"`
}

// HelloPubSub receives and processes a Pub/Sub push message.
func sendMail(w http.ResponseWriter, r *http.Request) {
	var m PubSubMessage
	body, err := io.ReadAll(r.Body)
	defer r.Body.Close()
	if err != nil {
		log.Printf("io.ReadAll: %v", err)
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}
	// byte slice unmarshalling handles base64 decoding.
	if err := json.Unmarshal(body, &m); err != nil {
		log.Printf("json.Unmarshal: %v", err)
		http.Error(w, "Bad Request", http.StatusBadRequest)
		return
	}

	subject, err := mailSubject(m.Message.Data)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
	}

	config := mailConfig{
		from:     mailFrom,
		to:       mailTo,
		subject:  subject,
		body:     string(m.Message.Data),
		server:   mailHost,
		port:     mailPort,
		username: os.Getenv(mailUsernameKey),
		password: os.Getenv(mailPasswordKey),
	}

	if err := send(config); err != nil {
		log.Println(err)
	} else {
		log.Printf("Mail sent successfully")
	}
}

type mailConfig struct {
	from     string
	to       string
	subject  string
	body     string
	server   string
	port     int
	username string
	password string
}

func send(config mailConfig) error {
	message := gomail.NewMessage()

	message.SetHeader("From", config.from)
	message.SetHeader("To", config.to)
	message.SetHeader("Subject", config.subject)
	message.SetBody("text/plain", config.body)

	dialer := gomail.NewDialer(config.server, config.port, config.username, config.password)

	return dialer.DialAndSend(message)
}

func mailSubject(data []byte) (string, error) {
	csMessage := &ConfigSyncMessage{}
	if err := json.Unmarshal(data, csMessage); err != nil {
		return "", fmt.Errorf("unmarshaling Config Sync message: %v", err)
	}

	var rsKind string
	if csMessage.RSNamespace == "config-management-system" {
		rsKind = "RootSync"
	} else {
		rsKind = "RepoSync"
	}

	return fmt.Sprintf("%s %s/%s %s", rsKind, csMessage.RSNamespace, csMessage.RSName, csMessage.Status), nil
}
