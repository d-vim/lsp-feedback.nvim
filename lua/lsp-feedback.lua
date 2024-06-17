local H = {}
H.lsp_requests = {}
H.slow_requests = {}
H.bad_response = {
	occurred = false,
	clear_status_handle = nil,
}
H.config = {
	slow_request = {
		threshold_ms = 1000,
		notify = false,
		icon = "⋯",
	},
	bad_response = {
		status_timeout_ms = 2000,
		icon = "✗",
	},
	tracked_requests = { "textDocument/definition" },
}

H.setup = function(user_config)
	H.config = vim.tbl_deep_extend("force", H.config, user_config or {})

	for _, r in ipairs(H.config.tracked_requests) do
		H.config.tracked_requests[r] = true
	end
end

H.build_request_key = function(client_id, request)
	return client_id .. ":" .. request.bufnr .. ":" .. request.method
end

H.add_slow_request = function(request_key, request)
	H.slow_requests[request_key] = (H.slow_requests[request_key] or 0) + 1

	if H.config.slow_request.notify then
		vim.notify("LSP: `" .. request.method .. "` is pending...", vim.log.levels.WARN)
	end
end

H.remove_slow_request = function(request_key)
	if H.slow_requests[request_key] == nil then
		return
	end

	if H.slow_requests[request_key] == 0 or H.slow_requests[request_key] == 1 then
		H.slow_requests[request_key] = nil
		return
	end

	H.slow_requests[request_key] = H.slow_requests[request_key] - 1
end

H.on_request_pending = function(event_data)
	local client_id = event_data.client_id
	local request = event_data.request
	local request_key = H.build_request_key(client_id, request)
	local request_data = H.lsp_requests[request_key]
	if request_data == nil then
		request_data = {
			ref_count = 0,
			notification_handles = {},
		}
	end

	request_data.ref_count = request_data.ref_count + 1
	table.insert(
		request_data.notification_handles,
		vim.defer_fn(function()
			H.add_slow_request(request_key, request)
		end, H.config.slow_request.threshold_ms)
	)

	H.lsp_requests[request_key] = request_data
end

H.on_request_terminate = function(event_data)
	local client_id = event_data.client_id
	local request = event_data.request
	local request_key = H.build_request_key(client_id, request)
	local request_data = H.lsp_requests[request_key]
	if request_data == nil then
		return
	end

	request_data.ref_count = request_data.ref_count - 1
	local handle = table.remove(request_data.notification_handles, 1)
	handle:stop()
	if handle:get_due_in() == 0 then
		H.remove_slow_request(request_key)
	end

	if request_data.ref_count == 0 then
		H.lsp_requests[request_key] = nil
	end
end

H.set_bad_response_status = function()
	if H.bad_response.occurred and H.bad_response.clear_status_handle ~= nil then
		H.bad_response.clear_status_handle:stop()
	end

	H.bad_response.occurred = true
	H.bad_response.clear_status_handle =
		vim.defer_fn(H.clear_bad_response_status, H.config.bad_response.status_timeout_ms)
	vim.cmd("redrawstatus")
end

H.clear_bad_response_status = function()
	H.bad_response.occurred = false
	vim.cmd("redrawstatus")
end

H.has_bad_response = function()
	return H.bad_response.occurred
end

H.has_slow_requst = function()
	return next(H.slow_requests) ~= nil
end

H.status_icon = function()
	if H.has_bad_response() then
		return H.config.bad_response.icon
	elseif H.has_slow_requst() then
		return H.config.slow_request.icon
	end

	return ""
end

vim.api.nvim_create_autocmd("LspRequest", {
	group = vim.api.nvim_create_augroup("drew-lsp-request", { clear = true }),
	callback = function(event)
		local client_id = event.data.client_id
		local request = event.data.request
		if client_id == nil or request == nil then
			return false
		end

		if not H.config.tracked_requests[request.method] then
			return
		end

		if request.type == "pending" then
			H.on_request_pending(event.data)
		elseif request.type == "cancel" or request.type == "complete" then
			H.on_request_terminate(event.data)
		end
	end,
})

local on_definition = vim.lsp.handlers["textDocument/definition"]
vim.lsp.handlers["textDocument/definition"] = function(err, result, ctx, config)
	on_definition(err, result, ctx, config)

	if ctx == nil or ctx.bufnr == nil or ctx.client_id == nil or ctx.method == nil then
		return
	end

	if not H.config.tracked_requests[ctx.method] then
		return
	end

	if result == nil or next(result) == nil then
		H.set_bad_response_status()
	end
end

return H
