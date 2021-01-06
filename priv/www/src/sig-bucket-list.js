/**
 * Copyright 2016 - 2021 SigScale Global Inc.
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *      http://www.apache.org/licenses/LICENSE-2.0
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

import { PolymerElement, html } from '@polymer/polymer/polymer-element.js';
import '@polymer/iron-ajax/iron-ajax.js';
import '@polymer/paper-fab/paper-fab.js';
import '@vaadin/vaadin-grid/theme/material/vaadin-grid.js';
import '@vaadin/vaadin-grid/vaadin-grid.js';
import '@vaadin/vaadin-grid/vaadin-grid-filter.js';
import '@vaadin/vaadin-grid/vaadin-grid-column-group.js';
import '@polymer/iron-icons/iron-icons.js';
import './style-element.js'

class bucketList extends PolymerElement {
	static get template() {
		return html`
			<style include="style-element"></style>
			<vaadin-grid
					id="balanceBucketGrid"
					active-item="{{activeItem}}"
					loading="{{loading}}"
					theme="no-border">
				<vaadin-grid-column width="15ex" flex-grow="5">
					<template class="header">
						<vaadin-grid-filter
								aria-label="Bucket Id"
								path="id"
								value="[[_filterBucId]]">
							<input
									slot="filter"
									placeholder="Bucket Id"
									value="{{_filterBucId::input}}"
									focus-target>
						</vaadin-grid-filter>
					</template>
					<template>[[item.id]]</template>
				</vaadin-grid-column>
				<vaadin-grid-column width="15ex" flex-grow="5">
					<template class="header">
						<vaadin-grid-filter
								aria-label="Product Id"
								path="product"
								value="[[_filterProdId]]">
							<input
									slot="filter"
									placeholder="Product Id"
									value="{{_filterProdId::input}}"
									focus-target>
						</vaadin-grid-filter>
					</template>
					<template>[[item.product]]</template>
				</vaadin-grid-column>
				<vaadin-grid-column-group>
					<template class="header">
						<div class="grouptitle">Balance</div>
					</template>
					<vaadin-grid-column width="12ex" flex-grow="2">
						<template class="header">
								Cents
						</template>
						<template>
							<div class="cell numeric">[[item.cents]]</div>
						</template>
					</vaadin-grid-column>
					<vaadin-grid-column width="12ex" flex-grow="2">
						<template class="header">
								Bytes
						</template>
						<template>
							<div class="cell numeric">[[item.remainedAmount]]</div>
						</template>
					</vaadin-grid-column>
					<vaadin-grid-column width="12ex" flex-grow="2">
						<template class="header">
								Seconds
						</template>
						<template>
							<div class="cell numeric">[[item.seconds]]</div>
						</template>
					</vaadin-grid-column>
				</vaadin-grid-column-group>
			</vaadin-grid>
			<div class="add-button">
				<paper-fab
						icon="add"
						on-tap = "showAddBucket">
				</paper-fab>
			</div>
			<iron-ajax
					id="getBucketBalance"
					url="/balanceManagement/v1/bucket/"
					rejectWithRequest>
			</iron-ajax>
		`;
	}

	static get properties() {
		return {
			loading: {
				type: Boolean,
				notify: true
			},
			etag: {
				type: String,
				value: null
			},
			_filterBucId: {
				type: Boolean
			},
			_filterProdId: {
				type: Boolean
			},
			activeItem: {
				observer: '_activeItemChanged',
			}
		}
	}

	ready() {
		super.ready();
		var grid = this.shadowRoot.getElementById('balanceBucketGrid');
		grid.dataProvider = this._getBuckets;
	}

	_activeItemChanged(item) {
		if(item != null) {
			var grid = this.shadowRoot.getElementById('balanceBucketGrid'); 
			grid.selectedItems = item ? [item] : [];
			document.body.querySelector('sig-app').shadowRoot.querySelector('sig-bucket-add').shadowRoot.getElementById('deleteBucketModal').open();
			document.body.querySelector('sig-app').shadowRoot.querySelector('sig-bucket-add').shadowRoot.getElementById('deleteBucId').value = item.id;
		}
	}

	_getBuckets(params, callback) {
		var grid = this;
		var bucketList = document.body.querySelector('sig-app').shadowRoot.querySelector('sig-bucket-list');
		var ajax = bucketList.shadowRoot.getElementById("getBucketBalance");
		delete ajax.params['filter'];
		function checkHead(param) {
			return param.path == "id" || param.path == "product";
		}
		params.filters.filter(checkHead).forEach(function(filter) {
			if (filter.value) {
				if(ajax.params['filter']) {
					ajax.params['filter'] += "]," + filter.path + ".like=[" + filter.value + "%";
				} else {
					ajax.params['filter'] = "\"[{" + filter.path + ".like=[" + filter.value + "%";
				}
			}
		});
		if (ajax.params['filter']) {
			ajax.params['filter'] += "]}]\"";
		}
		var handleAjaxResponse = function(request) {
			if(request) {
				bucketList.etag = request.xhr.getResponseHeader('ETag');
				var range = request.xhr.getResponseHeader('Content-Range');
				var range1 = range.split("/");
				var range2 = range1[0].split("-");
				if (range1[1] != "*") {
					grid.size = Number(range1[1]);
				} else {
					grid.size = Number(range2[1]) + grid.pageSize * 2;
				}
				var vaadinItems = new Array();
				function checkChar(characteristic){
					return characteristic.name == "id";
				}
				for (var index in request.response) {
					var newRecord = new Object();
					newRecord.id = request.response[index].id;
					if(request.response[index].product) {
						if(request.response[index].product.id) {
							newRecord.product = request.response[index].product.id;
						}
					}
					if(request.response[index].remainedAmount) {
						if(request.response[index].remainedAmount.units == "cents") {
							newRecord.cents = request.response[index].remainedAmount.amount;
						}
						if(request.response[index].remainedAmount.units == "seconds") {
							var Str = request.response[index].remainedAmount.amount;
							if(Str.includes("b")){
								var NewStrSec = Str.substring(0, Str.length - 1);
								newRecord.seconds = NewStrSec;
							}
						}
						if(request.response[index].remainedAmount.units == "octets") {
							var Str = request.response[index].remainedAmount.amount;
							if(Str.includes("b")){
								var NewStr = Str.substring(0, Str.length - 1);
								newRecord.remainedAmount = NewStr;
							}
						}
					}
					vaadinItems[index] = newRecord;
				}
				callback(vaadinItems);
			} else {
				grid.size = 0;
				callback([]);
			}
		};
		var handleAjaxError = function(error) {
			bucketList.etag = null;
			var toast = document.body.querySelector('sig-app').shadowRoot.getElementById('restError');
			toast.text = "Error";
			toast.open();
			if(!grid.size) {
				grid.size = 0;
			}
			callback([]);
		}
		if (ajax.loading) {
			ajax.lastRequest.completes.then(function(request) {
			var startRange = params.page * params.pageSize + 1;
			var endRange = startRange + params.pageSize - 1;
			ajax.headers['Range'] = "items=" + startRange + "-" + endRange;
			if (bucketList.etag && params.page > 0) {
				ajax.headers['If-Range'] = bucketList.etag;
			} else {
				delete ajax.headers['If-Range'];
			}
			return ajax.generateRequest().completes;
			}, handleAjaxError).then(handleAjaxResponse, handleAjaxError);
		} else {
			var startRange = params.page * params.pageSize + 1;
			var endRange = startRange + params.pageSize - 1;
			ajax.headers['Range'] = "items=" + startRange + "-" + endRange;
			if (bucketList.etag && params.page > 0) {
				ajax.headers['If-Range'] = bucketList.etag;
			} else {
				delete ajax.headers['If-Range'];
			}
			ajax.generateRequest().completes.then(handleAjaxResponse, handleAjaxError);
		}
	}

	showAddBucket(event) {
		document.body.querySelector('sig-app').shadowRoot.querySelector('sig-bucket-add').shadowRoot.getElementById('addBucketModal').open();
	}
}

window.customElements.define('sig-bucket-list', bucketList);