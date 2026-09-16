// Package main is the entry point for the cm-centipede server.
//
//	@title			cm-centipede API
//	@description	Cloud-Barista cm-centipede — Multi-cloud filesystem, object storage, and DBMS data migration subsystem.
//	@version		1.0.0
//	@contact.name	Cloud-Barista Community
//	@contact.url	https://github.com/cloud-barista/cm-centipede
//	@host			localhost:8085
//	@BasePath		/
//	@securityDefinitions.basic	BasicAuth
package main

import (
	_ "github.com/cloud-barista/cm-centipede/pkg/api/rest/docs"

	"github.com/cloud-barista/cm-centipede/pkg/api/rest"
	"github.com/cloud-barista/cm-centipede/pkg/api/rest/controller"
	"github.com/cloud-barista/cm-centipede/pkg/config"
	"github.com/cloud-barista/cm-centipede/pkg/cryptoutil"
	"github.com/cloud-barista/cm-centipede/pkg/db"
	"github.com/cloud-barista/cm-centipede/pkg/logger"
	"github.com/cloud-barista/cm-centipede/pkg/rsautil"
	"github.com/rs/zerolog/log"
)

func main() {
	// 1. Config
	config.Init()

	// 2. Logger
	logger.Init()

	// 3. Database
	if err := db.Open(); err != nil {
		log.Fatal().Err(err).Msg("failed to open database")
	}

	// 4. RSA key (honeybee response decryption)
	if err := rsautil.InitRSAKey(); err != nil {
		log.Fatal().Err(err).Msg("failed to initialise RSA key")
	}

	// 5. AES key (connection credential encryption, see pkg/connsec)
	cryptoutil.InitKey()

	// 6. Mark ready and start HTTP server (blocks until SIGINT/SIGTERM)
	controller.IsReady = true
	rest.Start()

	// 7. Cleanup after graceful shutdown
	db.Close()
}
