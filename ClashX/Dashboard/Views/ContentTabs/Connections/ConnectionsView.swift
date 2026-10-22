//
//  ConnectionsView.swift
//  ClashX Dashboard
//
//

import SwiftUI

struct ConnectionsView: View {

	@EnvironmentObject var data: ClashConnsStorage

	@EnvironmentObject var toolbarState: DashboardToolbarState
	@State private var searchString: String = ""
	@State private var filtered: [DBConnection] = []

	var body: some View {
		ConnectionsTableView(data: filtered)
			.background(Color(compatible: .textBackgroundColor))
			.task(id: computeTaskID) {
				await recomputeFiltered()
			}
			.onAppear {
				searchString = toolbarState.searchText
			}
			.onChange(of: toolbarState.searchText) { newValue in
				searchString = newValue
			}
			.onReceive(NotificationCenter.default.publisher(for: .stopConns)) { _ in
				stopConns()
			}
	}

	private var computeTaskID: String {
		"\(data.snapshotRevision)-\(toolbarState.connShowClosed)-\(toolbarState.connAppFilter)-\(toolbarState.connSourceIPFilter)-\(toolbarState.connInternalFilter)-\(searchString)"
	}

	private func recomputeFiltered() async {
		let source = toolbarState.connShowClosed ? data.closedConns : data.conns
		let appFilter = toolbarState.connAppFilter
		let keyword = searchString
		let sourceIP = toolbarState.connSourceIPFilter
		let showInternal = toolbarState.connInternalFilter
		let resolver = DashboardManager.shared.appNameResolver
		var result: [DBConnection] = []
		for conn in source {
			guard !Task.isCancelled else { return }
			if showInternal {
				let isInner = conn.metadata.type == "Inner" || "\(conn.metadata.sourceIP):\(conn.metadata.sourcePort)" == ":0"
				guard isInner else { continue }
			}
			guard conn.matches(keyword: keyword, sourceIP: sourceIP) else { continue }
			if !appFilter.isEmpty {
				let name = await resolver.appName(processPath: conn.metadata.processPath, process: conn.metadata.process)
				guard !Task.isCancelled else { return }
				guard name == appFilter else { continue }
			}
			result.append(conn)
		}
		guard !Task.isCancelled else { return }
		filtered = result
	}

	func stopConns() {
		Task {
			await ApiRequest.closeAllConnection()
		}
	}
}

struct ConnectionsView_Previews: PreviewProvider {
    static var previews: some View {
        ConnectionsView()
    }
}
