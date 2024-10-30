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

// Sample pubsub demonstrates use of the cloud.google.com/go/pubsub package from App Engine flexible environment.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strconv"

	"cloud.google.com/go/pubsub"
	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
	gomail "gopkg.in/mail.v2"
)

const (
	ENV_GCP_PROJECT  = "GOOGLE_CLOUD_PROJECT"
	ENV_PUBSUB_TOPIC = "PUBSUB_TOPIC"

	ENV_MAIL_FROM   = "MAIL_FROM"
	ENV_MAIL_TO     = "MAIL_TO"
	ENV_MAIL_SERVER = "MAIL_SERVER"
	ENV_MAIL_PORT   = "MAIL_PORT"

	SECRET_KEY_MAIL_USERNAME = "cs-pubsub-mail-username"
	SECRET_KEY_MAIL_PASSWORD = "cs-pubsub-mail-password"
)

const maxMessages = 10

func main() {
	ctx := context.Background()

	projectID := mustGetenv(ENV_GCP_PROJECT)
	pubsubClient, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		log.Fatal(err)
	}
	defer pubsubClient.Close()

	secretManagerClient, err := secretmanager.NewClient(ctx)
	if err != nil {
		log.Fatalf("failed to setup SecretManager client: %v", err)
	}
	defer secretManagerClient.Close()

	mailServerPort, err := strconv.Atoi(mustGetenv(ENV_MAIL_PORT))
	if err != nil {
		log.Fatalf("failed to convert mail server port from string to integer: %v", err)
	}
	config := mailServerConfig{
		from:     mustGetenv(ENV_MAIL_FROM),
		to:       mustGetenv(ENV_MAIL_TO),
		server:   mustGetenv(ENV_MAIL_SERVER),
		port:     mailServerPort,
		username: mustGetSecret(ctx, secretManagerClient, projectID, SECRET_KEY_MAIL_USERNAME),
		password: mustGetSecret(ctx, secretManagerClient, projectID, SECRET_KEY_MAIL_PASSWORD),
	}

	topicName := mustGetenv(ENV_PUBSUB_TOPIC)
	topic := pubsubClient.Topic(topicName)

	// Create the topic if it doesn't exist.
	exists, err := topic.Exists(ctx)
	if err != nil {
		log.Fatal(err)
	}
	if !exists {
		log.Fatalf("Topic %v doesn't exist.", topicName)
	}

	http.HandleFunc("/pubsub/send-email", sendMail(config))

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
		log.Printf("Defaulting to port %s", port)
	}

	log.Printf("Listening on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

func mustGetenv(k string) string {
	v := os.Getenv(k)
	if v == "" {
		log.Fatalf("%s environment variable not set.", k)
	}
	return v
}

func mustGetSecret(ctx context.Context, client *secretmanager.Client, projectID, secretID string) string {
	secretName := fmt.Sprintf("projects/%s/secrets/%s/versions/latest", projectID, secretID)
	req := &secretmanagerpb.AccessSecretVersionRequest{Name: secretName}
	result, err := client.AccessSecretVersion(ctx, req)
	if err != nil {
		log.Fatalf("failed to get secret %q: %v", secretID, err)
	}
	return string(result.Payload.Data)
}

type pushRequest struct {
	Message struct {
		Attributes map[string]string
		Data       []byte
		ID         string `json:"message_id"`
	}
	Subscription string
}

type sendMailHandler func(w http.ResponseWriter, r *http.Request)

func sendMail(config mailServerConfig) sendMailHandler {
	return func(w http.ResponseWriter, r *http.Request) {

		msg := &pushRequest{}
		if err := json.NewDecoder(r.Body).Decode(msg); err != nil {
			http.Error(w, fmt.Sprintf("Could not decode body: %v", err), http.StatusBadRequest)
			return
		}

		subject, err := mailSubject(msg.Message.Data)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		body := string(msg.Message.Data)

		if err := send(config, subject, body); err != nil {
			log.Printf("failed to send email: %v", err)
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		log.Printf("Mail sent successfully")
	}
}

type mailServerConfig struct {
	from     string
	to       string
	server   string
	port     int
	username string
	password string
}

func send(config mailServerConfig, subject, body string) error {
	message := gomail.NewMessage()

	message.SetHeader("From", config.from)
	message.SetHeader("To", config.to)
	message.SetHeader("Subject", subject)
	message.SetBody("text/plain", body)

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
