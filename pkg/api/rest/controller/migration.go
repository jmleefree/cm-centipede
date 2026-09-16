package controller

import (
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/google/uuid"
	"github.com/labstack/echo/v4"
	"gorm.io/gorm"

	"github.com/cloud-barista/cm-centipede/pkg/api/rest/model"
	migrationpkg "github.com/cloud-barista/cm-centipede/pkg/core/migration"
	"github.com/cloud-barista/cm-centipede/pkg/dao"
)

// CreateMigration godoc
//
//	@Summary		Create and start a migration
//	@Description	Creates a Migration record from the given plan and immediately starts execution asynchronously.
//	@Tags			migration
//	@Accept			json
//	@Produce		json
//	@Param			body	body		model.CreateMigrationReq				true	"Migration creation request"
//	@Success		201		{object}	model.ApiResponse[model.Migration]
//	@Failure		400		{object}	model.ApiResponse[any]
//	@Failure		500		{object}	model.ApiResponse[any]
//	@Router			/centipede/migration [post]
func CreateMigration(c echo.Context) error {
	var req model.CreateMigrationReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("invalid request body: "+err.Error()))
	}
	if req.Name == "" {
		return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("name is required"))
	}
	// Rejected here rather than defaulted silently: a misspelt "keeep" that ran
	// as "cleanup" would drop the very database it was meant to preserve.
	switch req.DBMSOnFailure {
	case "", model.DBMSOnFailureCleanup, model.DBMSOnFailureKeep:
	default:
		return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse(
			fmt.Sprintf("dbmsOnFailure must be %q or %q (got %q)",
				model.DBMSOnFailureCleanup, model.DBMSOnFailureKeep, req.DBMSOnFailure)))
	}

	m := &model.Migration{
		ID:            uuid.New().String(),
		Name:          req.Name,
		Description:   req.Description,
		Plan:          req.Plan,
		DBMSOnFailure: req.DBMSOnFailure,
		Status:        "pending",
	}
	if err := dao.CreateMigration(m); err != nil {
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("create migration: "+err.Error()))
	}

	go migrationpkg.DefaultExecutor.Execute(m.ID)

	return c.JSON(http.StatusCreated, model.SuccessResponse(*m))
}

// ListMigration godoc
//
//	@Summary		List migrations (paginated)
//	@Description	Returns a paginated list of migrations, optionally filtered by status.
//	@Tags			migration
//	@Produce		json
//	@Param			status		query		string	false	"Filter by status (pending|running|completed|failed|cancelled)"
//	@Param			page		query		int		false	"Page number (default 1)"
//	@Param			pageSize	query		int		false	"Page size (default 20, max 100)"
//	@Success		200			{object}	model.ApiResponse[model.ListResponse[model.Migration]]
//	@Failure		500			{object}	model.ApiResponse[any]
//	@Router			/centipede/migration [get]
func ListMigration(c echo.Context) error {
	status := c.QueryParam("status")
	page, pageSize := model.ParsePageParams(c)

	items, total, err := dao.ListMigration(status, page, pageSize)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("list migration: "+err.Error()))
	}

	return c.JSON(http.StatusOK, model.SuccessResponse(model.ListResponse[model.Migration]{
		Total:    total,
		Page:     page,
		PageSize: pageSize,
		Items:    items,
	}))
}

// ListAllMigration godoc
//
//	@Summary		List all migrations without pagination
//	@Description	Returns every migration record ordered by created_at DESC, optionally filtered by status.
//	@Tags			migration
//	@Produce		json
//	@Param			status	query		string	false	"Filter by status (pending|running|completed|failed|cancelled)"
//	@Success		200		{object}	model.ApiResponse[[]model.Migration]
//	@Failure		500		{object}	model.ApiResponse[any]
//	@Router			/centipede/migration/all [get]
func ListAllMigration(c echo.Context) error {
	status := c.QueryParam("status")

	items, err := dao.ListAllMigration(status)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("list all migration: "+err.Error()))
	}

	return c.JSON(http.StatusOK, model.SuccessResponse(items))
}

// GetMigration godoc
//
//	@Summary		Get a single migration
//	@Description	Returns the Migration record for the given ID.
//	@Tags			migration
//	@Produce		json
//	@Param			migrationId	path		string	true	"Migration ID"
//	@Success		200			{object}	model.ApiResponse[model.Migration]
//	@Failure		404			{object}	model.ApiResponse[any]
//	@Failure		500			{object}	model.ApiResponse[any]
//	@Router			/centipede/migration/{migrationId} [get]
func GetMigration(c echo.Context) error {
	id := c.Param("migrationId")

	m, err := dao.GetMigration(id)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return c.JSON(http.StatusNotFound, model.SimpleErrorResponse("migration not found: "+id))
		}
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("get migration: "+err.Error()))
	}

	return c.JSON(http.StatusOK, model.SuccessResponse(*m))
}

// DeleteMigration godoc
//
//	@Summary		Delete a migration
//	@Description	Deletes a migration record. Returns 409 if the migration is currently running — cancel it first.
//	@Tags			migration
//	@Produce		json
//	@Param			migrationId	path	string	true	"Migration ID"
//	@Success		204
//	@Failure		404	{object}	model.ApiResponse[any]
//	@Failure		409	{object}	model.ApiResponse[any]
//	@Failure		500	{object}	model.ApiResponse[any]
//	@Router			/centipede/migration/{migrationId} [delete]
func DeleteMigration(c echo.Context) error {
	id := c.Param("migrationId")

	if err := dao.DeleteMigration(id); err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return c.JSON(http.StatusNotFound, model.SimpleErrorResponse("migration not found: "+id))
		}
		if errors.Is(err, dao.ErrMigrationRunning) {
			return c.JSON(http.StatusConflict, model.SimpleErrorResponse("cannot delete a running migration; cancel it first"))
		}
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("delete migration: "+err.Error()))
	}

	return c.NoContent(http.StatusNoContent)
}

// CancelMigration godoc
//
//	@Summary		Cancel a running migration
//	@Description	Signals the running migration to stop after the current item finishes. Returns 404 if the migration is not currently running.
//	@Tags			migration
//	@Produce		json
//	@Param			migrationId	path		string	true	"Migration ID"
//	@Success		200			{object}	model.ApiResponse[model.Migration]
//	@Failure		404			{object}	model.ApiResponse[any]
//	@Failure		500			{object}	model.ApiResponse[any]
//	@Router			/centipede/migration/{migrationId}/cancel [post]
func CancelMigration(c echo.Context) error {
	id := c.Param("migrationId")

	if err := migrationpkg.DefaultExecutor.Cancel(id); err != nil {
		return c.JSON(http.StatusNotFound, model.SimpleErrorResponse("migration is not running: "+id))
	}

	m, err := dao.GetMigration(id)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("get migration after cancel: "+err.Error()))
	}

	return c.JSON(http.StatusOK, model.SuccessResponse(*m))
}

// RetryMigration godoc
//
//	@Summary		Retry a failed or cancelled migration
//	@Description	Creates a new Migration that re-runs items from the original according to retryMode. DBMS destination tables are DROP-ped before re-execution.
//	@Tags			migration
//	@Accept			json
//	@Produce		json
//	@Param			migrationId	path		string			true	"Original Migration ID"
//	@Param			body		body		model.RetryReq	false	"Retry options (retryMode: partial|full, default: partial)"
//	@Success		201			{object}	model.ApiResponse[model.RetryResponse]
//	@Failure		400			{object}	model.ApiResponse[any]
//	@Failure		404			{object}	model.ApiResponse[any]
//	@Failure		409			{object}	model.ApiResponse[any]
//	@Failure		500			{object}	model.ApiResponse[any]
//	@Router			/centipede/migration/{migrationId}/retry [post]
func RetryMigration(c echo.Context) error {
	id := c.Param("migrationId")

	var req model.RetryReq
	if err := c.Bind(&req); err != nil {
		return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse("invalid request body: "+err.Error()))
	}

	newMig, err := migrationpkg.DefaultExecutor.Retry(id, req.RetryMode)
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return c.JSON(http.StatusNotFound, model.SimpleErrorResponse("migration not found: "+id))
		}
		msg := err.Error()
		if strings.Contains(msg, "invalid retryMode") {
			return c.JSON(http.StatusBadRequest, model.SimpleErrorResponse(msg))
		}
		if strings.Contains(msg, "must be failed or cancelled") {
			return c.JSON(http.StatusConflict, model.SimpleErrorResponse(msg))
		}
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("retry migration: "+msg))
	}

	return c.JSON(http.StatusCreated, model.SuccessResponse(model.RetryResponse{
		OriginalMigrationID: id,
		NewMigration:        *newMig,
	}))
}

// ListMigrationLogs godoc
//
//	@Summary		List logs for a migration
//	@Description	Returns paginated MigrationLog entries for the given migration ID, optionally filtered by status.
//	@Tags			migration
//	@Produce		json
//	@Param			migrationId	path		string	true	"Migration ID"
//	@Param			status		query		string	false	"Filter by status (success|failed|skipped)"
//	@Param			page		query		int		false	"Page number (default 1)"
//	@Param			pageSize	query		int		false	"Page size (default 20, max 100)"
//	@Success		200			{object}	model.ApiResponse[model.ListResponse[model.MigrationLog]]
//	@Failure		500			{object}	model.ApiResponse[any]
//	@Router			/centipede/migration/{migrationId}/logs [get]
func ListMigrationLogs(c echo.Context) error {
	id := c.Param("migrationId")
	status := c.QueryParam("status")
	page, pageSize := model.ParsePageParams(c)

	items, total, err := dao.ListMigrationLog(id, status, page, pageSize)
	if err != nil {
		return c.JSON(http.StatusInternalServerError, model.SimpleErrorResponse("list migration logs: "+err.Error()))
	}

	return c.JSON(http.StatusOK, model.SuccessResponse(model.ListResponse[model.MigrationLog]{
		Total:    total,
		Page:     page,
		PageSize: pageSize,
		Items:    items,
	}))
}
