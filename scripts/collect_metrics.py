#!/usr/bin/env python3
import argparse, os, csv, datetime
from google.cloud import monitoring_v3
import pandas as pd
import matplotlib.pyplot as plt

def timeseries_to_df(series):
    # convert a timeseries to a DataFrame (timestamp, value)
    rows = []
    for point in series.points:
        t = point.interval.end_time
        v = None
        if point.value.double_value:
            v = point.value.double_value
        elif point.value.int64_value:
            v = point.value.int64_value
        rows.append({'time': pd.to_datetime(t), 'value': v})
    return pd.DataFrame(rows)

def fetch_metric(client, project, filter_, interval):
    results = client.list_time_series(
        request={
            "name": f"projects/{project}",
            "filter": filter_,
            "interval": interval,
            "view": monitoring_v3.ListTimeSeriesRequest.TimeSeriesView.FULL,
        }
    )
    return list(results)

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out-dir', default='results/metrics')
    parser.add_argument('--start', default=None)
    parser.add_argument('--end', default=None)
    args = parser.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    client = monitoring_v3.MetricServiceClient()
    project = client.common_project_path(os.environ['GOOGLE_CLOUD_PROJECT'])

    # Example: CPU utilization for instance (metric type: compute.googleapis.com/instance/cpu/utilization)
    now = datetime.datetime.utcnow()
    start = now - datetime.timedelta(minutes=60)
    interval = monitoring_v3.TimeInterval({
        "end_time": {"seconds": int(now.timestamp())},
        "start_time": {"seconds": int(start.timestamp())}
    })

    # Replace with your instance filter or aggregate across instances
    cpu_filter = 'metric.type="compute.googleapis.com/instance/cpu/utilization"'

    series = fetch_metric(client, os.environ['GOOGLE_CLOUD_PROJECT'], cpu_filter, interval)

    # For simplicity, write one CSV and plot mean
    frames = []
    for s in series:
        df = timeseries_to_df(s)
        frames.append(df.set_index('time').rename(columns={'value': s.metric.labels.get('instance_name','instance')}))
    # This part requires adjustments depending on the dimension labels - keep it flexible

    # Plot example (aggregate)
    plt.figure()
    for f in frames:
        f['value'].plot()
    plt.title('CPU utilization')
    plt.xlabel('time')
    plt.ylabel('utilization')
    plt.savefig(os.path.join(args.out_dir,'cpu_util.png'))

if __name__ == '__main__':
    main()
