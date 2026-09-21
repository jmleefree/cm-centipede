package controller

import (
	"errors"
	"fmt"
	"net/http"

	commonmodel "github.com/cloud-barista/cm-centipede/dmdl/common-model"
	targetmodel "github.com/cloud-barista/cm-centipede/dmdl/target-model"
	"github.com/cloud-barista/cm-centipede/pkg/api/rest/model"
	"github.com/cloud-barista/cm-centipede/pkg/connsec"
	"github.com/cloud-barista/cm-centipede/pkg/core/plan"
	"github.com/labstack/echo/v4"
)

// validateConnectionRef checks that source-specific sub-fields are present.
// Returns an empty string when valid.
func validateConnectionRef(ref commonmodel.ConnectionRef) string {
	switch ref.Source {
	case commonmodel.ConnectionSourceHoneybee:
		if ref.Honeybee == nil || ref.Honeybee.ConnectionID == "" {
			return "honeybee.connectionId is required"
		}
	case commonmodel.ConnectionSourceBeetleSSH:
		if ref.BeetleSSH == nil {
			return "beetleSsh is required"
		}
		if ref.BeetleSSH.NsID == "" || ref.BeetleSSH.InfraID == "" || ref.BeetleSSH.NodeID == "" {
			return "beetleSsh.nsId, infraId, nodeId are required"
		}
	case commonmodel.ConnectionSourceBeetleObjectStorage:
		if ref.BeetleOS == nil {
			return "beetleObjectStorage is required"
		}
		if ref.BeetleOS.NsID == "" || ref.BeetleOS.OsID == "" {
			return "beetleObjectStorage.nsId, osId are required"
		}
	case commonmodel.ConnectionSourceBeetleDB:
		if ref.BeetleDB == nil {
			return "beetleDb is required"
		}
		if ref.BeetleDB.NsID == "" || ref.BeetleDB.RdbmsID == "" {
			return "beetleDb.nsId, rdbmsId are required"
		}
		if ref.BeetleDB.Password == "" {
			return "beetleDb.password is required (managed RDB APIs do not return it)"
		}

	case commonmodel.ConnectionSourceSSH:
		if ref.SSH == nil {
			return "ssh is required"
		}
		if ref.SSH.Host == "" || ref.SSH.Username == "" {
			return "ssh.host, username are required"
		}
	case commonmodel.ConnectionSourceMinio:
		if ref.Minio == nil {
			return "minio is required"
		}
		if ref.Minio.ProviderName == "" || ref.Minio.AccessKeyId == "" || ref.Minio.SecretAccessKey == "" {
			return "minio.providerName, accessKeyId, secretAccessKey are required"
		}
		// openstack and onprem are the providers where the user supplies the host;
		// every other provider derives it (azure from the storage account name).
		switch ref.Minio.ProviderName {
		case commonmodel.ProviderOpenStack, commonmodel.ProviderOnPrem:
			if ref.Minio.Endpoint == "" {
				return "minio.endpoint is required for providerName openstack or onprem"
			}
		}
	case commonmodel.ConnectionSourceDB:
		if ref.DB == nil {
			return "db is required"
		}
		if ref.DB.ProviderName == "" || ref.DB.DBMSType == "" || ref.DB.AccessType == "" {
			return "db.providerName, dbmsType, accessType are required"
		}
		switch ref.DB.AccessType {
		case "direct":
			if ref.DB.Host == "" {
				return "db.host is required for accessType=direct"
			}
		case "sshTunnel":
			if ref.DB.SSHTunnel == nil || ref.DB.SSHTunnel.Host == "" || ref.DB.SSHTunnel.Username == "" {
				return "db.sshTunnel.host, username are required for accessType=sshTunnel"
			}
		default:
			return "db.accessType must be 'direct' or 'sshTunnel'"
		}

	default:
		// Without this the switch accepted anything it did not recognise,
		// including the empty string: the `oneof` tag on Source looks like it
		// covers that, but no validator is registered on the echo instance, so
		// the tags never run.
		return fmt.Sprintf(
			"unknown source %q (must be one of: honeybee, beetleSsh, beetleObjectStorage, beetleDb, ssh, minio, db)",
			ref.Source)
	}
	return ""
}

// GetTargetPlan godoc
//
//	@Summary		Analyse target migration plan
//	@Description	Validates source/destination connections, checks DBMS compatibility and version, and returns a TargetDataMigrationModel ready for CreateMigration.
//	@Tags			plan
//	@Accept			json
//	@Produce		json
//	@Param			body	body		model.TargetPlanReq									true	"Target plan request"
//	@Success		200		{object}	model.ApiResponse[targetmodel.TargetDataMigrationModel]
//	@Failure		400		{object}	model.ApiResponse[any]
//	@Failure		500		{object}	model.ApiResponse[any]
//	@Router			/centipede/plans/target [post]
func GetTargetPlan(c echo.Context) error {
	var req model.TargetPlanReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("invalid request body: "+err.Error()))
	}

	// Validate destination ConnectionRef
	if msg := validateConnectionRef(req.DstConnection); msg != "" {
		return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("dstConnection: "+msg))
	}

	// Validate each source connection
	src := req.Source.SourceDataMigrationModel
	for _, fs := range src.FileSystems {
		if msg := validateConnectionRef(fs.Connection); msg != "" {
			return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("fileSystem source connection: "+msg))
		}
	}
	for _, os := range src.ObjectStorages {
		if msg := validateConnectionRef(os.Connection); msg != "" {
			return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("objectStorage source connection: "+msg))
		}
	}
	for _, db := range src.Databases {
		if msg := validateConnectionRef(db.Connection); msg != "" {
			return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("db source connection: "+msg))
		}
	}

	result, err := plan.BuildTargetDataMigrationModel(req)
	if err != nil {
		var ve *plan.ValidationError
		if errors.As(err, &ve) {
			return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse(err.Error()))
		}
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse(err.Error()))
	}

	// The request carried plaintext because a person typed it; the answer does
	// not, because the caller pastes it into POST /migration unchanged and it
	// lives in a terminal, a file or a log in between. Encrypting here rather
	// than inside the builder keeps the plan layer working in plaintext.
	if err := connsec.EncryptPlan(&result); err != nil {
		return c.JSON(http.StatusInternalServerError,
			model.SimpleErrorResponse("encrypt plan: "+err.Error()))
	}

	return c.JSON(http.StatusOK, model.SuccessResponse[targetmodel.TargetDataMigrationModel](result))
}
